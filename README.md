# Mass Action Scheduler (home-grown, callout-free)

A reusable Salesforce package that runs a **Flow** or **invocable Apex** action over the
records returned by a **SOQL query**, on demand or on a schedule — a home-grown
replacement for the archived `dca_mass_action` package.

**Key difference from the original:** it requires **no Named Credential, no Connected App,
and no Remote Site Setting.** All work is done natively in Apex:

| Concern | How it works |
|---|---|
| Identify records | `Database.getQueryLocator(Source_SOQL_Query__c)` |
| Invoke Flow / Apex | `Invocable.Action.createCustomAction('flow'\|'apex', name)` (in-process, bulk) |
| Discover target inputs | `Invocable.Action.getDescribe().getInputs()` (Flow **and** Apex) |
| List active flows | `FlowDefinitionView` SOQL |
| Schedule | `System.schedule()` + stored CronTrigger Id |
| Logging | `MAS_GIC_Log__c` summary + per-batch error rows |

## Components

- **Objects:** `MAS_GIC_Configuration__c`, `MAS_GIC_Field_Mapping__c` (master-detail child),
  `MAS_GIC_Log__c`.
- **Apex:** `MAS_GIC_BatchRunner` (Batchable/Stateful), `MAS_GIC_Scheduler` (Schedulable),
  `MAS_GIC_ConfigController` (`@AuraEnabled` for the wizard), `MAS_GIC_RunConfigInvocable`
  (`@InvocableMethod` for programmatic runs), `MAS_GIC_Utils`, `MAS_GIC_SampleAction` (demo target).
- **LWC:** `masGicConfigWizard`, `masGicConfigList`, `masGicLogViewer`.
- **App / access:** `GIC Mass Action Scheduler` app + tabs, `MAS_GIC_Admin` permission set.

## Setup (scratch org dev loop)

> Requires an authorized Dev Hub. The `GIC Developer` Dev Hub currently needs
> re-authentication:
> `sf org login web --alias "GIC Developer" --set-default-dev-hub`

```bash
# from the project root
sf org create scratch -f config/project-scratch-def.json -a mas-dev -d 30
sf project deploy start -o mas-dev
sf org assign permset -n MAS_GIC_Admin -o mas-dev
sf apex run test -o mas-dev -l RunLocalTests -w 10
```

Also grant the wizard user **Manage Flow** ("View Setup and Configuration") so the flow
picker can see all active autolaunched flows.

## Usage

1. Open the **GIC Mass Action Scheduler** app → **MAS Configurations** → **New**.
2. Enter a **Source SOQL Query**; click **Preview** to confirm columns/rows.
3. Pick a **Target Type** (Flow or Apex) and the action; the wizard auto-loads its input
   parameters.
4. Map source columns (or literals) to target parameters.
5. Set a **Batch Size** (keep ~50 for Flow targets — invoked flows share the batch
   transaction's governor limits).
6. **Run Now**, or set a **Schedule** (cron) and mark the config **Active**.
7. Review results under **Logs**.

Programmatic run (from a Flow/automation): call **Run Mass Action Configuration**
(`MAS_GIC_RunConfigInvocable`) with a Configuration Id or Developer Name.

## Packaging (2GP unlocked)

```bash
sf package create -n "Mass Action Scheduler" -t Unlocked -r force-app
sf package version create -p "Mass Action Scheduler" -x -w 30 -c
# install into a target org (e.g. LWV CSPartial) for UAT
sf package install -p <version-id> -o "LWV CSPartial" -w 30
```

## Notes / caveats

- **Callout-free** unless the *target* Flow/Apex itself makes a callout; a target that
  does an async callout after DML can raise "uncommitted work pending".
- Max 100 concurrent scheduled Apex jobs org-wide; the config stores its CronTrigger Id
  and aborts it on reschedule/deactivate.
- Runs as the launching (Run Now) or scheduling user — no impersonation.
- A record page for `MAS_GIC_Configuration__c` embedding `masGicConfigWizard` + `masGicLogViewer`
  can be created in Lightning App Builder after deploy (or added as a FlexiPage).
