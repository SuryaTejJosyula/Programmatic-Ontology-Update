# Update-Ontology.ps1

## Introduction

Microsoft Fabric Ontologies define the entity types and relationships that describe your data model — things like `Customer`, `Order`, `Product`, and the properties they carry (`customer_id`, `order_date`, `status`, etc.).

The **Fabric portal provides a UI** for modifying an existing ontology's entity types after they are created but this requires manual work on the UI which is error prome. This PowerShell script provides a way to automate the creation and modification of entities programatically which makes it repeatable, reusable and less error prone.  Changes must go through the Fabric REST API, which requires constructing a correctly-structured JSON payload, base64-encoding every part, and handling asynchronous (LRO) responses. A single mistake in field structure causes the entire import to fail with a vague `ALMOperationImportFailed` error.

**`Update-Ontology.ps1`** solves this by giving you an interactive, menu-driven terminal workflow that:

- Fetches your live ontology definition from Fabric
- Lets you queue multiple changes in one session — add new entity types, add properties to existing ones, or remove properties — without touching the live ontology until you confirm
- Validates the payload before upload (rebuilds corrupted `entityIdParts`, deduplicates properties, ensures required arrays are non-null)
- Submits the full updated definition back to Fabric and verifies the changes landed, handling the known Fabric post-import warning transparently
- Saves diagnostic JSON files to `%TEMP%` after every run so you can inspect exactly what was sent

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **Azure CLI** | [Install guide](https://aka.ms/installazurecliwindows). Run `az login` before the script. |
| **PowerShell 7+** | `winget install Microsoft.PowerShell` |
| **Fabric permissions** | Your account needs `Item.ReadWrite.All` (delegated) on the workspace |

---

## How to use

### 1 — Open a terminal and log in

```powershell
az login
```

### 2 — Run the script

```powershell
cd C:\Users\sujosyul\ontology_update
.\Update-Ontology.ps1
```

You can also pass the IDs directly to skip the prompts:

```powershell
.\Update-Ontology.ps1 -WorkspaceId "<your-workspace-guid>" -OntologyId "<your-ontology-item-guid>"
```

### 3 — Enter your Workspace ID and Ontology ID (if not passed as parameters)

The script will prompt for both GUIDs. You can find them in the Fabric portal URL when viewing your ontology item.

---

## Action menu

After fetching the current definition, the script shows existing entity types and presents a repeating menu:

```
  Actions: [A] Add new entity type   [E] Edit existing entity type   [S] Submit   [Q] Quit
```

You can run **A** and **E** as many times as you like before pressing **S** to push all changes at once.

---

## Adding a new entity type  `[A]`

1. Choose **A** from the menu.
2. Enter a **name** for the new entity type (letters, numbers, `_`, `-`; must start with a letter; max 128 chars). The name must be unique in the ontology.
3. Add **regular properties** one at a time:
   - Enter a property name
   - Choose a value type: `String`, `Boolean`, `DateTime`, `BigInt`, `Double`, `Object`
   - The **first property you add becomes the entity ID key and display-name property** — choose something like `order_id` or `customer_id` first.
   - Answer `y` to add more regular properties, or press Enter to move on.
4. Optionally add **timeseries properties** (e.g. sensor readings with timestamps) following the same prompts.
5. The new entity is queued locally. Repeat step 1–4 to queue additional entities.
6. When finished, choose **S** to submit all queued changes to Fabric.

**Example session:**

```
  Actions: A / E / S / Q  >  a

  ── New Entity Type ──
  Entity type name: Product

  Regular properties (non-timeseries):
  (The first property becomes the display-name and entity-ID key.)
    Property name: product_id
    Value type [String/Boolean/DateTime/BigInt/Double/Object]: String
    Add another regular property? [y/N]: y
    Property name: product_name
    Value type: String
    Add another regular property? [y/N]: y
    Property name: unit_price
    Value type: Double
    Add another regular property? [y/N]: n

  Add timeseries properties? [y/N]: n

✓ Entity type 'Product' queued.
```

---

## Editing an existing entity type  `[E]`

1. Choose **E** from the menu.
2. Select the entity type by number from the displayed list.
3. The entity's current regular and timeseries properties are shown. Choose an inner action:

| Key | Action |
|-----|--------|
| `A` | Add a new **regular** property |
| `T` | Add a new **timeseries** property |
| `R` | Remove a property (cannot remove the entity-ID key property) |
| `D` | Done — return to the main menu |

4. After choosing **D**, the edited entity is marked for update. Choose **S** from the main menu to push to Fabric.

**Adding a property:**

```
  Actions: A / T / R / D  >  a
  Property name: shipping_address
  Value type [String/Boolean/DateTime/BigInt/Double/Object]: String
✓ Regular property 'shipping_address' [String] added.
```

**Removing a property:**

```
  Actions: A / T / R / D  >  r
  Remove from: [R] Regular properties  [T] Timeseries properties  >  r
    [1] product_id  [String]
    [2] product_name  [String]
    [3] unit_price  [Double]
    [4] shipping_address  [String]
  Property number to remove (1-4): 4
✓ Regular property 'shipping_address' removed.
```

> **Note:** You cannot remove the first property of an entity — it is used as the entity ID key and display name. If you need to change it, add a new entity type instead.

---

## Submitting changes  `[S]`

Choosing **S** from the main menu:

1. Shows a summary of all queued additions and edits
2. Asks for final confirmation (`Y/n`)
3. Runs pre-flight checks on the payload (validates/rebuilds `entityIdParts`, deduplicates properties, ensures required fields)
4. Uploads the full updated definition to Fabric
5. Verifies the changes are present in the live ontology by re-fetching it
6. Prints a success message

---

## Diagnostic files

All files are written to your `%TEMP%` folder:

| File | Created when | Contents |
|------|-------------|----------|
| `fabric-ontology-update-body.json` | Before every upload | Complete request body sent to Fabric |
| `fabric-new-entity-{name}.json` | When adding an entity | Decoded JSON of the new entity definition |
| `fabric-edit-{entityId}.json` | When editing an entity | Side-by-side `original` and `updated` entity JSON |
| `fabric-dirty-before-{name}.json` | Pre-flight, before re-encode | Entity JSON as loaded from current payload |
| `fabric-ontology-last-error.json` | On any API error | Full raw HTTP error response from Fabric |
