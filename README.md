# Aug Prescience Frames (ElvUI module)

Two quick “slot” frames to help an Augmentation Evoker cast **Prescience** on selected players.

## Install

1. Exit WoW.
2. Ensure the addon folder is exactly:
   - `World of Warcraft/_retail_/Interface/AddOns/AugPrescienceFrames/`
3. Make sure **ElvUI** is installed and enabled.
4. Launch WoW and enable **Aug Prescience Frames** on the character AddOns screen.
5. `/reload`

## What it does

- Adds **2 small clickable frames** (“Slot 1” and “Slot 2”).
- Use keybinds to **store a friendly player** into Slot 1/2.
- **Click a slot** to cast **Prescience** on that stored player.
- **Hover a slot** to make it the real `@mouseover` unit (so mouseover-cast macros work).
- Shows **class color** (name + border) and a **Prescience buff tracker** icon with remaining time.
- Optional **Prescience range** indicator: red frame border, dimmed bar, and **OOR** when the slotted player is out of cast range (toggle in ElvUI options).

## Keybinds (recommended setup)

Open **Esc → Options → Key Bindings → Aug Prescience Frames**:

- **Add current unit to Slot 1**
- **Add current unit to Slot 2**
- **Clear slots**

When you press “Add Slot 1/2”, it will store the first valid unit found in this order:

1. `target`
2. `mouseover`
3. `focus`

The unit must be **a friendly player**.
In a party/raid, the addon stores a stable unit token (`partyX`/`raidX`) so the slot stays correct even if you change targets.

### Mouseover casting (optional)

If you want to cast Prescience without clicking the slot, you can bind a macro like:

```lua
#showtooltip Prescience
/cast [@mouseover,help,nodead][] Prescience
```

Then **hover** Slot 1/2 and press your Prescience key.

## Moving the frames (ElvUI mover)

1. Type `/moveui`
2. Find **“Aug Prescience Frames”**
3. Drag it where you want
4. Click **Lock**

## Configuration (ElvUI options)

- Open ElvUI config (default: `/ec`) and go to **Aug Prescience Frames**
- Or type: `/apf config`

Options include:

- Enable/disable
- Width / height / spacing
- Transparent style
- Clear slots
- **Name** section: font size, strip opacity, shadow, outline, text color

## Slash commands

- `/apf show` / `/apf hide`
- `/apf clear`
- `/apf config`

## Combat restrictions (important)

Because the slot buttons are **secure action buttons** (so clicking them can cast Prescience), some changes are restricted in combat:

- Updates to the secure “unit” attribute are deferred until you leave combat if needed.
- The addon avoids showing/hiding secure buttons in combat (it soft-disables via transparency and mouse input instead).

