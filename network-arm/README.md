# network-arm

This is the **ARM-era Azure-Deploy path** — `network.json` is an Azure-Deploy `structureVersion
3.9.1` / `containerVersion 3.0.10` deployment definition (`DeployContainerAddress`-shaped, the
format the Azure-Deploy container consumes), and `network.bicep` is the single-file Bicep template
that same Azure-Deploy pipeline compiled.

**This is legacy for Azure Repos targets.** `bicep-action` is the current deployment engine there
(D-14); Azure-Deploy is preserved as the still-supported path for whatever targets have not moved
to `bicep-action` yet, not presented as a current build target for anything new. Phase 1
deliberately did not publish the 2020-era `configVersion 1.0.0.0` ARM files
(`empty.json`/`iaas.json`/`paas.json`/`network-vdc-arm.json`) for exactly this reason — this
architype exists to preserve the already-published `structureVersion 3.9.1` generation, not to
mirror a non-target as if it were current.

See [`../README.md`](../README.md) and
[`docs/main/concierge-seeding-contract.md`](https://github.com/innofactororg/concierge-app/blob/main/docs/main/concierge-seeding-contract.md)
in `concierge-app` for the manifest schema this folder's `manifest.json` conforms to.
