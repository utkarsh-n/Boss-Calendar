# Public source snapshot

This repository contains a reviewed source snapshot. Original Git history, credentials, personal records, local signing identities, device diagnostics, build outputs, downloaded model weights, firmware, and unreviewed media are excluded. Existing upstream license and attribution files apply to their respective components. Publication does not grant a new license to third-party content.

Configure your own Apple signing team to run native apps on a physical device. Downloaded datasets, binary runtimes, fonts, demo media, and models may need to be obtained separately using the documented upstream sources or fetch/build tools. This publication review does not certify that this snapshot builds or runs.

## Project setup and omitted assets

The planner and app source contain no exported personal calendar/idea database. Clone [OfflineIntelligenceKit](https://github.com/utkarsh-n/OfflineIntelligenceKit) as the sibling directory `OfflineIntelligenceKit`; the XcodeGen manifest references both its core package and `MLX` subpackage. Shared local model weights are omitted; use that package's documented verified model setup. Supply your own signing team and generate the project with XcodeGen.
