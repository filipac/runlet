"""The AI providers' stand-in for screenshot scripts (#368, #44, #45), shared by
scripts/ai-screenshots.py (the pull requests' screenshots and checks) and
scripts/docs-screenshots.py (the AI Assistance page's).

`Stub` runs Tests/Fixtures/ai-stub/router.php under `php -S` on 127.0.0.1 with a scenario, and
logs what it received; point the app at it with `RUNLET_AI_BASE_URL` (Debug builds only). Nothing
here contacts Anthropic or OpenAI, and the key is made up. The rest is the scratch data both
scripts use: a class that throws for a negative invoice line, a tab that calls it, the stand-in's
canned answer, and its proposed fix; and a chat about them (`CHAT_*`), two questions and their
answers.
"""
from __future__ import annotations

import json
from pathlib import Path
import shutil
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
ROUTER = ROOT / "Tests" / "Fixtures" / "ai-stub" / "router.php"

#: Made up, never a real key: Settings shows it as `sk-ant-…0000`.
KEY = "sk-ant-api03-EXAMPLE-not-a-real-key-0000"
MASKED = "sk-ant-…0000"

#: app/Services/InvoiceTotals.php: throws for a negative line, from a collection callback.
INVOICE_TOTALS = """<?php

namespace App\\Services;

use DomainException;

class InvoiceTotals
{
    /**
     * The invoice's total, in cents.
     */
    public function sum(array $lines): int
    {
        return collect($lines)
            ->map(fn (int $cents) => $this->checked($cents))
            ->sum();
    }

    private function checked(int $cents): int
    {
        if ($cents < 0) {
            throw new DomainException("Invoice line is negative: {$cents} cents");
        }

        return $cents;
    }
}
"""

#: The tab: a refund line makes InvoiceTotals throw.
INVOICE = """<?php

use App\\Services\\InvoiceTotals;

$lines = [1999, 2500, -300];

$totals = new InvoiceTotals();
echo $totals->sum($lines);
"""

#: The fix the stand-in proposes (without the tab's final line break, as models write it).
FIXED = """<?php

use App\\Services\\InvoiceTotals;

$lines = [1999, 2500, -300];
$charges = array_filter($lines, fn (int $cents) => $cents >= 0);

$totals = new InvoiceTotals();
echo $totals->sum($charges);"""

#: The stand-in's answer: an explanation that refers to the fix, then the fix, as the
#: instructions ask (`ExplainErrorPrompt.instructions`).
ANSWER = f"""`InvoiceTotals::sum()` passes every line through `checked()`, which throws a `DomainException` for an amount below zero. The third line, `-300`, is a refund, so the check stops the whole sum on it.

`sum()` only adds charges, so leave refunds out before you call it. The proposed fix below does that, and the total becomes 4,499 cents. If refunds belong on the invoice, keep them in a list of their own and subtract their sum from the total.

```runlet-fix
{FIXED}
```"""

#: The answer quickly, all of it.
QUICK = {"answer": ANSWER, "chunk": 24, "delay_ms": 5}
#: The answer slowly, pausing after its first paragraph, so a picture catches it streaming.
STREAMING = {"answer": ANSWER, "chunk": 9, "delay_ms": 25, "hold_after": 230, "hold_ms": 7000}


#: The chat (#45): the first question mentions the class with @, so its source goes with it.
CHAT_FIRST = "Why does @app/Services/InvoiceTotals.php throw for this invoice? Refunds should lower the total."
CHAT_SECOND = "Can it print the total in dollars?"
CHAT_FILE = "app/Services/InvoiceTotals.php"

#: The answers, one per turn, each with a code block for Insert into Tab.
CHAT_ANSWERS = [
    """`InvoiceTotals::sum()` passes every line through `checked()`, which throws a `DomainException` for an amount below zero, so the refund line `-300` stops the whole sum.

Keep `sum()` for charges, and subtract the refunds yourself:

```php
$charges = array_filter($lines, fn (int $cents) => $cents >= 0);
$refunds = array_filter($lines, fn (int $cents) => $cents < 0);

echo $totals->sum($charges) + array_sum($refunds);
```

That prints `4199`: 4,499 cents of charges, less the 300-cent refund.""",
    """Yes. Laravel's `Number` helper formats an amount as currency, so divide the cents by 100 first:

```php
use Illuminate\\Support\\Number;

$total = $totals->sum($charges) + array_sum($refunds);

echo Number::currency($total / 100, in: 'USD');
```

That prints `$41.99`. Keep the cents for anything you store, and format only what you show.""",
]

#: The chat's answers quickly.
CHAT_QUICK = {"answers": CHAT_ANSWERS, "chunk": 24, "delay_ms": 5}
#: The second answer slowly, pausing after its first sentence, so a picture catches it streaming.
CHAT_STREAMING = {"answers": CHAT_ANSWERS, "chunk": 8, "delay_ms": 25, "hold_after": 150, "hold_ms": 7000, "hold_turn": 2}


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def seed_project(project: Path) -> None:
    """Adds the throwing class to a project folder (a copy of a Laravel app)."""
    (project / "app" / "Services").mkdir(parents=True, exist_ok=True)
    (project / "app" / "Services" / "InvoiceTotals.php").write_text(INVOICE_TOTALS)


class Stub:
    """The stand-in under `php -S 127.0.0.1:<port>`, with a scenario (router.php lists its keys)
    and a log of the requests it received. `kill()` and `wait()` stop it, like a Popen's."""

    def __init__(self, folder: Path, scenario: dict, port: int | None = None):
        php = shutil.which("php")
        if not php:
            raise RuntimeError("the AI stand-in needs PHP on PATH")
        folder.mkdir(parents=True, exist_ok=True)
        self.folder = folder
        (folder / "scenario.json").write_text(json.dumps(scenario))
        self.log = folder / "requests.jsonl"
        self.log.unlink(missing_ok=True)
        self.port = port or free_port()
        self.process = subprocess.Popen([php, "-S", f"127.0.0.1:{self.port}", str(ROUTER)], cwd=folder,
                                        env={"PATH": "/usr/bin:/bin", "RUNLET_AI_STUB_SCENARIO": str(folder / "scenario.json"),
                                             "RUNLET_AI_STUB_LOG": str(self.log)},
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 10
        while time.time() < deadline:
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", self.port)) == 0:
                    return
            time.sleep(0.05)
        self.kill()
        raise RuntimeError(f"the AI stand-in didn't start on 127.0.0.1:{self.port}")

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def requests(self) -> list[dict]:
        """What the stand-in received: the path, the provider, "present" for the key (never the
        key), and the body."""
        if not self.log.is_file():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines() if line.strip()]

    def kill(self) -> None:
        self.process.terminate()

    def wait(self, timeout: float = 5) -> None:
        try:
            self.process.wait(timeout)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()

    def stop(self) -> None:
        self.kill()
        self.wait()
