import Foundation

/// Lets a terminal tab know when the user's login shell has finished starting, so a command
/// is typed at its first real prompt and never into a question an rc file asks while it
/// loads (e.g. `dotenv: found '.env' file. Source it?`, an oh-my-zsh update prompt).
///
/// The shell reports readiness with a private escape sequence, `ESC ] 6973 ; RunletReady ;
/// <token> BEL`, written once just before its first prompt; the token is random per tab.
/// Only tabs that type a command use it; plain shells start exactly as before.
///
/// - zsh: `ZDOTDIR` points at Runlet's directory, whose `.zshenv`, `.zprofile`, `.zshrc`,
///   and `.zlogin` source the user's files of the same name with the user's own `ZDOTDIR`
///   set while they run (as zsh would), restore that `ZDOTDIR` for good after the last one,
///   and add a one-shot `precmd` hook. precmd first runs once every startup file is done.
/// - bash: a non-login interactive shell with `--rcfile`: the rc file reads what `bash -l`
///   reads (`/etc/profile`, then the first of `~/.bash_profile`, `~/.bash_login`,
///   `~/.profile`) and adds a one-shot `PROMPT_COMMAND` entry. Differences from a real
///   login shell: `shopt login_shell` is off, `$0` is `bash`, `logout` refuses, and
///   `~/.bash_logout` is not read.
/// - fish: `--init-command` (runs after config.fish) defines a one-shot `fish_prompt` handler.
///
/// Nothing is printed during startup (Powerlevel10k's instant prompt warns about console
/// output), zsh and bash write the marker to `/dev/tty` (past any redirection of stdout),
/// and the hooks remove themselves and every variable and function they defined.
public enum ShellIntegration {
    public enum Shell: String, Sendable, CaseIterable {
        case zsh, bash, fish

        /// The shell an executable path names (`/bin/zsh`, `/opt/homebrew/bin/fish`), if supported.
        public init?(executable path: String) {
            let name = (path as NSString).lastPathComponent
            self.init(rawValue: name.hasPrefix("-") ? String(name.dropFirst()) : name)
        }
    }

    /// OSC number of the readiness marker (unassigned; SwiftTerm swallows unknown OSCs).
    public static let oscCode = 6973
    /// Carries the per-tab token to zsh and bash; their scripts unset it before any user file runs.
    public static let tokenVariable = "RUNLET_SHELL_READY_TOKEN"
    /// The user's own `ZDOTDIR` (present only when the inherited environment had one).
    public static let userZdotdirVariable = "RUNLET_USER_ZDOTDIR"

    /// A fresh random token (32 hex digits).
    public static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The complete marker the shell writes: `ESC ] 6973 ; RunletReady ; <token> BEL`.
    public static func readyMarker(token: String) -> [UInt8] {
        Array("\u{1b}]\(oscCode);RunletReady;\(token)\u{07}".utf8)
    }

    /// Finds the readiness marker in terminal output that arrives in arbitrary chunks (a
    /// marker split across reads is still found).
    public struct ReadyScanner: Sendable {
        private let marker: [UInt8]
        private var matched = 0
        public private(set) var found = false

        public init(token: String) {
            marker = ShellIntegration.readyMarker(token: token)
            // ESC only starts the marker, so a mismatch can only restart a match at ESC.
            precondition(!marker.dropFirst().contains(0x1b), "the token must not contain ESC")
        }

        /// Scans the next chunk; true once the marker has been seen (in this chunk or earlier).
        @discardableResult
        public mutating func scan<Bytes: Sequence>(_ bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
            guard !found else { return true }
            for byte in bytes {
                if byte == marker[matched] {
                    matched += 1
                    if matched == marker.count {
                        found = true
                        return true
                    }
                } else {
                    matched = byte == marker[0] ? 1 : 0
                }
            }
            return false
        }
    }

    // MARK: Scripts

    /// Directory with the zsh startup files (used as `ZDOTDIR`).
    public static func zshDirectory(in root: URL) -> URL { root.appendingPathComponent("zsh", isDirectory: true) }

    /// The bash rc file (passed with `--rcfile`).
    public static func bashRCFile(in root: URL) -> URL { root.appendingPathComponent("bash/runlet.bash") }

    /// Writes the scripts under `root` (replacing changed or missing files; unchanged files
    /// are left alone) and returns `root`.
    @discardableResult
    public static func install(in root: URL) throws -> URL {
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            if (try? String(contentsOf: url, encoding: .utf8)) == contents { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url, options: .atomic)
        }
        return root
    }

    /// Relative path → contents of every installed script.
    static let files: [(String, String)] = [
        ("zsh/.zshenv", zshenv),
        ("zsh/.zprofile", zshStartupFile(".zprofile")),
        ("zsh/.zshrc", zshrc),
        ("zsh/.zlogin", zlogin),
        ("bash/runlet.bash", bashrc),
    ]

    /// The `--init-command` that makes fish report its first prompt.
    public static func fishInitCommand(token: String) -> String {
        "function __runlet_ready --on-event fish_prompt; functions --erase __runlet_ready; "
            + "printf '\\e]\(oscCode);RunletReady;%s\\a' \(token); end"
    }

    private static let zshHeader = #"""
    # Runlet shell integration (zsh). Runlet points ZDOTDIR here only for a terminal tab that
    # will type a command. Each file sources the user's file of the same name with the user's
    # ZDOTDIR in place, as zsh would; .zlogin then leaves the user's ZDOTDIR set and adds a
    # one-shot precmd hook that tells Runlet the first prompt is about to be drawn.
    # Generated by Runlet; changes are overwritten.

    """#

    private static let zshenv = zshHeader + #"""
    typeset -g _runlet_dir="$ZDOTDIR" _runlet_token="${RUNLET_SHELL_READY_TOKEN-}" _runlet_home=
    if (( ${+RUNLET_USER_ZDOTDIR} )); then
      typeset -g _runlet_user_set=1 _runlet_user_zdotdir="$RUNLET_USER_ZDOTDIR" _runlet_user_export=1
    else
      typeset -g _runlet_user_set=0 _runlet_user_zdotdir= _runlet_user_export=0
    fi
    builtin unset RUNLET_USER_ZDOTDIR RUNLET_SHELL_READY_TOKEN

    # Puts the user's ZDOTDIR in place (value and export flag, or unset); _runlet_home is
    # where zsh reads the user's startup files from.
    _runlet_user() {
      builtin emulate -L zsh
      if (( _runlet_user_set )); then
        if (( _runlet_user_export )); then
          builtin export ZDOTDIR="$_runlet_user_zdotdir"
        else
          builtin typeset -g +x ZDOTDIR="$_runlet_user_zdotdir"
        fi
        _runlet_home="$_runlet_user_zdotdir"
      else
        builtin unset ZDOTDIR
        _runlet_home="$HOME"
      fi
    }

    # After a user file: remembers the user's ZDOTDIR and points zsh back here for its next
    # startup file, or finishes when zsh reads no more of them (NO_RCS, not a login shell).
    _runlet_ours() {
      builtin emulate -L zsh
      if (( ${+ZDOTDIR} )); then
        _runlet_user_set=1 _runlet_user_zdotdir="$ZDOTDIR"
        if [[ ${(t)ZDOTDIR} == *-export* ]]; then _runlet_user_export=1; else _runlet_user_export=0; fi
      else
        _runlet_user_set=0 _runlet_user_zdotdir= _runlet_user_export=0
      fi
      if [[ -o rcs && -o login ]]; then
        builtin typeset -g +x ZDOTDIR="$_runlet_dir"
      else
        _runlet_finish
      fi
    }

    # Startup is over and the user's ZDOTDIR is in place: arm the readiness hook and remove
    # everything else this integration defined.
    _runlet_finish() {
      builtin emulate -L zsh
      typeset -g __runlet_ready_token="$_runlet_token"
      precmd_functions+=(__runlet_ready)
      builtin unset _runlet_dir _runlet_token _runlet_home _runlet_user_set _runlet_user_zdotdir _runlet_user_export
      builtin unfunction _runlet_user _runlet_ours _runlet_finish
    }

    # Runs before the first prompt (after every startup file), once.
    __runlet_ready() {
      local ret=$?
      builtin emulate -L zsh
      precmd_functions=(${precmd_functions:#__runlet_ready})
      { builtin printf '\e]6973;RunletReady;%s\a' "$__runlet_ready_token" >/dev/tty; } 2>/dev/null ||
        builtin printf '\e]6973;RunletReady;%s\a' "$__runlet_ready_token"
      builtin unset __runlet_ready_token
      builtin unfunction __runlet_ready
      return ret
    }

    _runlet_user
    if [[ -r $_runlet_home/.zshenv ]]; then builtin source "$_runlet_home/.zshenv"; fi
    _runlet_ours

    """#

    private static func zshStartupFile(_ name: String) -> String {
        zshHeader + """
        _runlet_user
        if [[ -r $_runlet_home/\(name) ]]; then builtin source "$_runlet_home/\(name)"; fi
        _runlet_ours

        """
    }

    private static let zshrc = zshHeader + #"""
    _runlet_user
    # /etc/zshrc sets HISTFILE from ZDOTDIR, which was Runlet's while it ran.
    if [[ ${HISTFILE-} == "$_runlet_dir/.zsh_history" ]]; then HISTFILE=${_runlet_home:-$HOME}/.zsh_history; fi
    if [[ -r $_runlet_home/.zshrc ]]; then builtin source "$_runlet_home/.zshrc"; fi
    _runlet_ours

    """#

    private static let zlogin = zshHeader + #"""
    _runlet_user
    if [[ -r $_runlet_home/.zlogin ]]; then builtin source "$_runlet_home/.zlogin"; fi
    _runlet_finish

    """#

    private static let bashrc = #"""
    # Runlet shell integration (bash). Runlet starts `bash --rcfile <this file> -i` only for a
    # terminal tab that will type a command. This file reads what a login shell (bash -l)
    # reads, then adds a one-shot PROMPT_COMMAND entry that tells Runlet the first prompt is
    # about to be drawn. Generated by Runlet; changes are overwritten.

    __runlet_ready_token=${RUNLET_SHELL_READY_TOKEN-}
    unset RUNLET_SHELL_READY_TOKEN

    if [ -r /etc/profile ]; then . /etc/profile; fi
    if [ -r ~/.bash_profile ]; then . ~/.bash_profile
    elif [ -r ~/.bash_login ]; then . ~/.bash_login
    elif [ -r ~/.profile ]; then . ~/.profile
    fi

    # Runs before the first prompt, once: removes its own PROMPT_COMMAND entry (wherever
    # other hooks moved it) and reports the prompt.
    __runlet_ready() {
      local ret=$? nl=$'\n' i
      if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]] && (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
        for i in "${!PROMPT_COMMAND[@]}"; do
          if [[ ${PROMPT_COMMAND[i]} == __runlet_ready ]]; then unset 'PROMPT_COMMAND[i]'; fi
        done
      elif [[ ${PROMPT_COMMAND-} == __runlet_ready ]]; then
        if [[ -n ${__runlet_prompt_command_set-} ]]; then PROMPT_COMMAND=; else unset PROMPT_COMMAND; fi
      else
        PROMPT_COMMAND=${PROMPT_COMMAND//"$nl"__runlet_ready/}
        PROMPT_COMMAND=${PROMPT_COMMAND#__runlet_ready"$nl"}
      fi
      { builtin printf '\033]6973;RunletReady;%s\007' "${__runlet_ready_token-}" >/dev/tty; } 2>/dev/null ||
        builtin printf '\033]6973;RunletReady;%s\007' "${__runlet_ready_token-}"
      unset __runlet_ready_token __runlet_prompt_command_set
      unset -f __runlet_ready
      return $ret
    }

    __runlet_prompt_command_set=${PROMPT_COMMAND+1}
    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]] && (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
      PROMPT_COMMAND+=(__runlet_ready)
    elif [[ -n ${PROMPT_COMMAND-} ]]; then
      PROMPT_COMMAND="$PROMPT_COMMAND
    __runlet_ready"
    else
      PROMPT_COMMAND=__runlet_ready
    fi

    """#
}
