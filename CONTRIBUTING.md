# Contributing

Thanks for looking. This repo is a **toolkit**, not a product: the most valuable contributions are
usually one small tool or one verification idea, not a big refactor.

- New here? Read [`README.md`](README.md) (English) or [`README.zh-CN.md`](README.zh-CN.md).
- Design rules and known constraints: [`docs/12-CONVENTIONS.md`](docs/12-CONVENTIONS.md).
- What is deliberately *not* possible: [`docs/07`](docs/07-NO-MACOS-AT-ALL.md), [`docs/11`](docs/11-NO-DEVICE-VERIFICATION.md).

## Run it first

```powershell
.\scripts\install.ps1 -Dev            # Python deps (pinned), verifies zig + openssl
python -m pytest py_tests -q          # 14 unit tests, no network, no Apple account
.\scripts\lint.ps1                    # ruff + PSScriptAnalyzer + parse check
.\tools\test-nomac-build.ps1          # 10-step end-to-end (build → sign → ipa → audit → simulate)
```

All four must pass before a PR. CI runs the same on `ubuntu-latest` and `windows-latest`.

## Ground rules

| Rule | Why |
|---|---|
| PowerShell files are **UTF-8 with BOM** | PS 5.1 reads BOM-less UTF-8 as GBK and eats the next line — this bit us repeatedly |
| Python: `main()` + `sys.exit()`, no side effects at import | tools must be importable by tests |
| Exit codes: `0` pass, `1` blocking, `2` warnings only | see `docs/12` |
| Every Mach-O change must re-run `audit-device.py` **and** `sim-ios.py` | structure bugs are invisible until dyld tries to load it |
| No Apple SDK files in the repo | `sdk/iPhoneOS-shim` is hand-written symbols only |
| Secrets never in git | `.p8`, `.p12`, `.mobileprovision`, `.env`, `refresh.json` are gitignored |

## Gaps we would love help with

Ordered by "value to others" ÷ "effort". Pick anything; open an issue first if it is large.

### Good first issue

| # | Gap | Where | Acceptance |
|---|---|---|---|
| 1 | **Share the duplicated Mach-O parser** — the same load-command walking code exists in 5 tools | `tools/{machogen,codesign_lite,verify-ipa,audit-device,sim-ios}.py` | one `tools/macho.py`, all tools import it, tests still green |
| 2 | **`--json` everywhere** — `audit-device.py` and `verify-ipa.py` should emit machine-readable results | both tools | schema documented, CI can assert on it |
| 3 | **English error messages** — tools print Chinese; the public README is English | all tools | `LANG`/`--lang` switch, Chinese kept as default |
| 4 | **`actool`-free icon fallback hardening** — verify loose PNGs on more iOS versions | `tools/make-icons.py`, `docs/09` | document which iOS builds honour `CFBundleIconFiles` |
| 5 | **Symbol discovery for `.tbd` shims** — today new APIs compile fine and crash at runtime | `sdk/iPhoneOS-shim`, `scripts/xc` | scan headers/`nm` output and propose missing symbols |

### Help wanted

| # | Gap | Notes |
|---|---|---|
| 6 | **Real-device validation matrix** | iOS 15/16/17/18 × TrollStore / free-sign / paid. `docs/16` explains the paths; we only need reported results (device, iOS, path, result, syslog excerpt) to fill a table |
| 7 | **App Store submission** | `POST /v1/appStoreVersions` → `reviewSubmissions` → `reviewSubmissionItems`. Auth reuses `scripts/lib/AscJwt.ps1`; add endpoints to `tools/mock-asc-server.py` so it stays testable offline |
| 8 | **`Assets.car` writer** | the one genuinely missing Apple artifact. Format is BOM + `RENDITIONS` tree; a minimal writer for app icons would remove the last "you can't submit" caveat |
| 9 | **Nested-code sealing** | `codesign` records hashes of `Frameworks/*` in the parent signature. `make-resources.py` covers resources only |
| 10 | **Deterministic real-cert signing** | CMS embeds a signing time, so `-Deterministic` only holds for ad-hoc. An option to pin the CMS time would make releases reproducible |
| 11 | **Bigger app shapes** | the build takes a single `.m`. A tiny build graph (multiple sources, headers, static libs) would let realistic apps use this |

### Research (hard, open-ended)

| # | Gap | Why it is hard |
|---|---|---|
| 12 | **SwiftUI without Xcode** | needs a Swift frontend that targets `arm64-apple-ios` **and** the SDK's `.swiftmodule`. `scripts/xc/Get-IosSdk.ps1` gets you the modules; the compiler is the open question |
| 13 | **macOS-free `ibtool`** | nib format is undocumented; code-built UI is the pragmatic answer |
| 14 | **Better than zld for `MH_EXECUTE`** | our dylib+loader split exists only because zig's linker overflows on executables with external symbols. If that is fixed upstream (or an `ld64.lld` binary lands), the split should go away — see `docs/08` |
| 15 | **Faster emulator** | `sim-ios.py` runs one scenario in ~2 s; a clock/cache model would allow perf-ish assertions |

## Reporting a device result (most useful contribution)

> **As of the v1.0.0 tag, nothing from this repo has ever been launched on a physical device.**
> Every claim is Windows-side: compile, sign, package, static audit, emulated execution.
> One device report is worth more than a feature PR right now.

> **As of the v1.0.0 tag, no build from this repo has ever been launched on a physical device.**
> Every claim here is Windows-side: compile, sign, package, static audit, emulated execution.
> A single device report is worth more than a feature PR.

If you install the sample on a phone, please open an issue with:

```
device / iOS version / install path (TrollStore | free | paid)
result (launched | black screen | crash at launch | install failed)
syslog excerpt:  pymobiledevice3 syslog live --process AppCore
audit output:    python tools/audit-device.py <ipa> --target <path>
```

Two things we specifically want to confirm or falsify (see `docs/10` §C):
`UIApplicationMain` being called from a dylib constructor, and 4 KB signature pages.

## Style

- Comments explain **why**, in the language the surrounding file already uses.
- Prefer a 20-line tool over a 200-line abstraction.
- If a change makes an existing doc statement false, update the doc in the same PR.

## License

By contributing you agree your work is licensed under the repo's [MIT license](LICENSE).
