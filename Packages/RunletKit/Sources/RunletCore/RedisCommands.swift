import Foundation

/// Redis tabs (#190): what each command does, from a built-in table derived from Redis 7.2's
/// command flags (`COMMAND INFO`: `readonly`, `write`, `admin`, `dangerous`, `blocking`,
/// `pubsub`). Container commands (`CONFIG`, `CLIENT`, …) are classified per subcommand
/// (`CONFIG|GET`). A command the table doesn't know counts as a write. The runner keeps the
/// same lists (`RedisCommands` in RedisTab.php; `RedisCommandTableTests` compares them) and,
/// on a read-only connection, also asks the server's `COMMAND INFO` before sending anything.
public enum RedisCommands {
    /// How a command touches the server.
    public enum Access: String, Sendable, Equatable {
        /// Reads data or server state only.
        case read
        /// Connection state only: AUTH, SELECT, PING, CLIENT SETNAME, …
        case connection
        /// MULTI, EXEC, DISCARD, WATCH, UNWATCH.
        case transaction
        /// Can change data, the server's configuration, or other clients.
        case write
        /// Subscribes or streams (SUBSCRIBE, MONITOR, …): Runlet doesn't stream replies yet.
        case streaming
        /// Not in the table: treated as a write.
        case unknown
    }

    /// The classification of one command line.
    public struct Info: Sendable, Equatable {
        /// `GET`, or `CONFIG GET` for a container's subcommand.
        public var name: String
        public var access: Access
        /// Always confirms, naming the command, on every connection (#190).
        public var dangerous: Bool
        /// Waits on the server (BLPOP, XREAD BLOCK, WAIT, …): Stop ends it.
        public var blocking: Bool
        /// Why it's dangerous, for the confirmation.
        public var danger: String?

        /// Whether a read-only connection may send it.
        public var allowedReadOnly: Bool { access == .read || access == .connection || access == .transaction }
    }

    /// Commands with subcommands, classified as `NAME|SUB`.
    public static let containers: Set<String> = [
        "ACL", "CLIENT", "CLUSTER", "COMMAND", "CONFIG", "FUNCTION", "LATENCY", "MEMORY", "MODULE", "OBJECT", "PUBSUB",
        "SCRIPT", "SLOWLOG", "XGROUP", "XINFO",
    ]

    /// Reads (`readonly` in Redis's flags, or read-only admin commands such as INFO and CONFIG GET).
    public static let reads: Set<String> = [
        // Keys and strings
        "GET", "MGET", "GETRANGE", "SUBSTR", "STRLEN", "EXISTS", "TYPE", "TTL", "PTTL", "EXPIRETIME", "PEXPIRETIME", "DBSIZE",
        "RANDOMKEY", "SCAN", "KEYS", "DUMP", "TOUCH", "LCS", "SORT_RO", "GETBIT", "BITCOUNT", "BITPOS", "BITFIELD_RO",
        "OBJECT|ENCODING", "OBJECT|FREQ", "OBJECT|IDLETIME", "OBJECT|REFCOUNT", "OBJECT|HELP",
        // Hashes
        "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HSTRLEN", "HSCAN", "HRANDFIELD",
        "HTTL", "HPTTL", "HEXPIRETIME", "HPEXPIRETIME",
        // Lists
        "LINDEX", "LLEN", "LRANGE", "LPOS",
        // Sets
        "SCARD", "SISMEMBER", "SMISMEMBER", "SMEMBERS", "SRANDMEMBER", "SSCAN", "SINTER", "SINTERCARD", "SUNION", "SDIFF",
        // Sorted sets
        "ZCARD", "ZCOUNT", "ZLEXCOUNT", "ZRANGE", "ZRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGE", "ZREVRANGEBYSCORE",
        "ZREVRANGEBYLEX", "ZRANK", "ZREVRANK", "ZSCORE", "ZMSCORE", "ZSCAN", "ZRANDMEMBER", "ZINTER", "ZINTERCARD", "ZUNION", "ZDIFF",
        // Streams
        "XRANGE", "XREVRANGE", "XLEN", "XREAD", "XPENDING", "XINFO|STREAM", "XINFO|GROUPS", "XINFO|CONSUMERS", "XINFO|HELP",
        "XGROUP|HELP",
        // Geo and HyperLogLog
        "GEOPOS", "GEODIST", "GEOHASH", "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO", "GEOSEARCH", "PFCOUNT",
        // Scripting that can't write
        "EVAL_RO", "EVALSHA_RO", "FCALL_RO", "SCRIPT|EXISTS", "SCRIPT|HELP", "FUNCTION|LIST", "FUNCTION|DUMP", "FUNCTION|STATS",
        "FUNCTION|HELP",
        // Server state
        "INFO", "TIME", "LASTSAVE", "ROLE", "LOLWUT", "MEMORY|USAGE", "MEMORY|STATS", "MEMORY|DOCTOR", "MEMORY|MALLOC-STATS",
        "MEMORY|HELP", "LATENCY|LATEST", "LATENCY|HISTORY", "LATENCY|DOCTOR", "LATENCY|GRAPH", "LATENCY|HISTOGRAM",
        "LATENCY|HELP", "SLOWLOG|GET", "SLOWLOG|LEN", "SLOWLOG|HELP", "CONFIG|GET", "CONFIG|HELP", "CLIENT|LIST",
        "CLIENT|INFO", "CLIENT|ID", "CLIENT|GETNAME", "CLIENT|GETREDIR", "CLIENT|TRACKINGINFO", "CLIENT|HELP", "COMMAND",
        "COMMAND|COUNT", "COMMAND|DOCS", "COMMAND|GETKEYS", "COMMAND|GETKEYSANDFLAGS", "COMMAND|INFO", "COMMAND|LIST",
        "COMMAND|HELP", "MODULE|LIST", "MODULE|HELP", "ACL|WHOAMI", "ACL|LIST", "ACL|USERS", "ACL|GETUSER", "ACL|CAT",
        "ACL|LOG", "ACL|GENPASS", "ACL|DRYRUN", "ACL|HELP", "PUBSUB|CHANNELS", "PUBSUB|NUMSUB", "PUBSUB|NUMPAT",
        "PUBSUB|SHARDCHANNELS", "PUBSUB|SHARDNUMSUB", "PUBSUB|HELP", "CLUSTER|INFO", "CLUSTER|NODES", "CLUSTER|SLOTS",
        "CLUSTER|SHARDS", "CLUSTER|MYID", "CLUSTER|MYSHARDID", "CLUSTER|KEYSLOT", "CLUSTER|COUNTKEYSINSLOT",
        "CLUSTER|GETKEYSINSLOT", "CLUSTER|LINKS", "CLUSTER|HELP",
    ]

    /// Connection state, allowed on read-only connections.
    public static let connection: Set<String> = [
        "AUTH", "HELLO", "PING", "ECHO", "SELECT", "QUIT", "RESET", "READONLY", "READWRITE", "ASKING", "WAIT", "WAITAOF",
        "CLIENT|SETNAME", "CLIENT|SETINFO", "CLIENT|TRACKING", "CLIENT|CACHING", "CLIENT|NO-EVICT", "CLIENT|NO-TOUCH",
    ]

    /// Transaction control.
    public static let transaction: Set<String> = ["MULTI", "EXEC", "DISCARD", "WATCH", "UNWATCH"]

    /// Commands whose replies stream, or that stop replies: Runlet refuses them (a Redis tab
    /// reads one reply per command). Pub/Sub and MONITOR streaming is a later feature.
    public static let streaming: Set<String> = [
        "SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "UNSUBSCRIBE", "PUNSUBSCRIBE", "SUNSUBSCRIBE", "MONITOR", "SYNC", "PSYNC",
        "REPLCONF", "CLIENT|REPLY",
    ]

    /// Writes: data, scripts that may write, and server changes.
    public static let writes: Set<String> = [
        "SET", "SETNX", "SETEX", "PSETEX", "MSET", "MSETNX", "GETSET", "GETDEL", "GETEX", "APPEND", "SETRANGE", "INCR", "INCRBY",
        "INCRBYFLOAT", "DECR", "DECRBY", "DEL", "UNLINK", "EXPIRE", "PEXPIRE", "EXPIREAT", "PEXPIREAT", "PERSIST", "RENAME",
        "RENAMENX", "MOVE", "COPY", "RESTORE", "RESTORE-ASKING", "SORT", "SETBIT", "BITOP", "BITFIELD",
        "HSET", "HSETNX", "HMSET", "HDEL", "HINCRBY", "HINCRBYFLOAT", "HEXPIRE", "HPEXPIRE", "HEXPIREAT", "HPEXPIREAT", "HPERSIST",
        "LPUSH", "LPUSHX", "RPUSH", "RPUSHX", "LPOP", "RPOP", "LINSERT", "LSET", "LREM", "LTRIM", "RPOPLPUSH", "LMOVE", "LMPOP",
        "BLPOP", "BRPOP", "BRPOPLPUSH", "BLMOVE", "BLMPOP",
        "SADD", "SREM", "SPOP", "SMOVE", "SINTERSTORE", "SUNIONSTORE", "SDIFFSTORE",
        "ZADD", "ZINCRBY", "ZREM", "ZREMRANGEBYRANK", "ZREMRANGEBYSCORE", "ZREMRANGEBYLEX", "ZPOPMIN", "ZPOPMAX", "BZPOPMIN",
        "BZPOPMAX", "ZMPOP", "BZMPOP", "ZRANGESTORE", "ZINTERSTORE", "ZUNIONSTORE", "ZDIFFSTORE",
        "XADD", "XDEL", "XTRIM", "XACK", "XCLAIM", "XAUTOCLAIM", "XSETID", "XREADGROUP", "XGROUP|CREATE", "XGROUP|SETID",
        "XGROUP|DESTROY", "XGROUP|CREATECONSUMER", "XGROUP|DELCONSUMER",
        "GEOADD", "GEORADIUS", "GEORADIUSBYMEMBER", "GEOSEARCHSTORE", "PFADD", "PFMERGE", "PFDEBUG", "PFSELFTEST",
        "EVAL", "EVALSHA", "FCALL", "SCRIPT|LOAD", "SCRIPT|KILL", "FUNCTION|LOAD", "FUNCTION|RESTORE", "FUNCTION|KILL",
        "PUBLISH", "SPUBLISH",
        "BGSAVE", "BGREWRITEAOF", "CONFIG|RESETSTAT", "SLOWLOG|RESET", "LATENCY|RESET", "MEMORY|PURGE", "CLIENT|PAUSE",
        "CLIENT|UNPAUSE", "CLIENT|UNBLOCK", "ACL|SAVE", "ACL|LOAD", "CLUSTER|ADDSLOTS", "CLUSTER|ADDSLOTSRANGE",
        "CLUSTER|DELSLOTS", "CLUSTER|DELSLOTSRANGE", "CLUSTER|SETSLOT", "CLUSTER|MEET", "CLUSTER|REPLICATE",
        "CLUSTER|BUMPEPOCH", "CLUSTER|SET-CONFIG-EPOCH", "CLUSTER|COUNT-FAILURE-REPORTS", "CLUSTER|SAVECONFIG",
    ]

    /// Dangerous commands (#190): they always confirm, naming the command, even off production.
    /// The value says why.
    public static let dangerous: [String: String] = [
        "FLUSHALL": "deletes every key in every database",
        "FLUSHDB": "deletes every key in the current database",
        "KEYS": "walks the whole keyspace in one call and blocks the server meanwhile; use SCAN (or the key browser) instead",
        "SWAPDB": "swaps two databases for every client",
        "SHUTDOWN": "stops the Redis server",
        "DEBUG": "can crash, block, or change the server (DEBUG is for Redis's developers)",
        "MIGRATE": "moves keys to another server and deletes them here",
        "REPLICAOF": "makes the server a replica of another (dropping its data) or a primary",
        "SLAVEOF": "makes the server a replica of another (dropping its data) or a primary",
        "SAVE": "writes the dataset to disk in the foreground, blocking every client meanwhile",
        "FAILOVER": "hands the primary role to a replica",
        "CONFIG|SET": "changes the server's configuration for every client",
        "CONFIG|REWRITE": "rewrites the server's configuration file",
        "SCRIPT|FLUSH": "removes every cached Lua script",
        "CLIENT|KILL": "closes other clients' connections",
        "MODULE|LOAD": "loads code into the server",
        "MODULE|LOADEX": "loads code into the server",
        "MODULE|UNLOAD": "unloads a module from the server",
        "ACL|SETUSER": "creates or changes a user's permissions",
        "ACL|DELUSER": "deletes users and closes their connections",
        "FUNCTION|FLUSH": "deletes every function library",
        "FUNCTION|DELETE": "deletes a function library",
        "CLUSTER|RESET": "resets the cluster node, dropping its data",
        "CLUSTER|FAILOVER": "forces a cluster failover",
        "CLUSTER|FORGET": "removes a node from the cluster",
        "CLUSTER|FLUSHSLOTS": "drops the node's slots",
    ]

    /// Commands that wait on the server; Stop ends them by closing the connection.
    public static let blocking: Set<String> = [
        "BLPOP", "BRPOP", "BRPOPLPUSH", "BLMOVE", "BLMPOP", "BZPOPMIN", "BZPOPMAX", "BZMPOP", "WAIT", "WAITAOF",
    ]

    /// Whether `name` (`GET`, or `CONFIG|GET`) is in the table.
    public static func isKnown(_ name: String) -> Bool {
        let name = name.uppercased()
        return reads.contains(name) || connection.contains(name) || transaction.contains(name) || streaming.contains(name)
            || writes.contains(name) || dangerous[name] != nil || containers.contains(name)
    }

    /// The table's key for a command line: `CONFIG|GET` for a container's subcommand.
    public static func key(_ arguments: [String]) -> String {
        guard let first = arguments.first?.uppercased() else { return "" }
        if containers.contains(first), arguments.count > 1 { return first + "|" + arguments[1].uppercased() }
        return first
    }

    /// Classifies a command line (its arguments, the name first).
    public static func classify(_ arguments: [String]) -> Info {
        let key = key(arguments)
        let name = key.replacingOccurrences(of: "|", with: " ")
        let upper = arguments.map { $0.uppercased() }
        var access: Access
        if streaming.contains(key) {
            access = .streaming
        } else if transaction.contains(key) {
            access = .transaction
        } else if connection.contains(key) {
            access = .connection
        } else if reads.contains(key) {
            access = .read
        } else if writes.contains(key) || dangerous[key] != nil {
            access = .write
        } else {
            access = .unknown
        }
        // An argument that makes a reading command write: ACL LOG RESET.
        if key == "ACL|LOG", upper.dropFirst(2).contains("RESET") { access = .write }
        let blocks = blocking.contains(key) || ((key == "XREAD" || key == "XREADGROUP") && upper.contains("BLOCK"))
        return Info(name: name, access: access, dangerous: dangerous[key] != nil, blocking: blocks, danger: dangerous[key])
    }

    /// Why a read-only connection refuses `arguments`, after "Runlet refused … on the read-only
    /// connection “x”: it …"; nil when it may run.
    public static func readOnlyRefusal(_ arguments: [String]) -> String? {
        let info = classify(arguments)
        switch info.access {
        case .read, .connection, .transaction: return nil
        case .write: return "can change data or the server (\(info.name))"
        case .streaming: return "streams replies (\(info.name)), which Redis tabs don't read yet"
        case .unknown: return info.name.isEmpty ? "is empty" : "is a command Runlet doesn't know (\(info.name)), so it can't tell whether it writes"
        }
    }

    /// Why a Redis tab never sends `arguments`, on any connection: streaming commands (Runlet
    /// reads one reply per command) and CLIENT REPLY OFF/SKIP.
    public static func refusal(_ arguments: [String]) -> String? {
        let info = classify(arguments)
        guard info.access == .streaming else { return nil }
        if info.name == "CLIENT REPLY" {
            return "CLIENT REPLY turns replies off, and Runlet reads one reply per command. Nothing ran."
        }
        return "\(info.name) streams messages until the connection closes, and Redis tabs read one reply per command (streaming is a later feature). Use redis-cli for \(info.name). Nothing ran."
    }
}
