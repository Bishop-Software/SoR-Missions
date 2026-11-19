# SoR-Missions

Runs the four SoR group missions for a boxed group: zones the group in, starts the
event, and handles each mission's mechanics (target order, add balancing, moving the
group between rooms, burns).

> **Stay at the keyboard.** This script drives a whole mission for you, but it is an
> assist, not an AFK bot. Watch it the whole time, and step in when something goes wrong.

## Missions

| Mission | Giver | What the script handles |
|---|---|---|
| Echo of Hate | Kerina | The four mini rooms (ports out and back), the illusion item check, greedlings, the phase 2 burn |
| Waxwork Abolishion | Defense Unit CDL | Keeping the adds' HP balanced, then finishing them lowest first; the tank steps out of the add pack; Rampage per wave |
| Colossus | Black Jay | Dragging each worker onto its aura, the AE feign, the burn at the first add wave |
| Shar'Drahn | Gwork | Stepping out of storms, Storm Call circles for an assigned toon, the burn at the first Storm Call |

## Requirements

- **MQ2Nav**, with meshes for the mission zones.
- **MQ2DanNet** or **MQ2EQBC**, for group commands. EQBC is used when the whole group is
  on it; otherwise DanNet.
- A **CWTN class plugin** on each toon, or **MQ2Boxr** for mode control (Manual, Camp,
  Chase).
- A group of your own boxes. A merc or a player who is not on your DanNet/EQBC can be in
  the group: they are not sent commands and have to play themselves.

## Use

Run it on every toon in the group:

```
/lua run SoR-Missions
```

Get the mission task, stand at the giver with the group, and click **Start Event** in the
window (or `/sorm start`). The start:

1. Checks that every box is running the script. With auto-launch on (the default), it runs
   `/lua run SoR-Missions` on any of your own boxes that do not answer. This only happens
   after you click Start, and only on toons on your DanNet/EQBC. Turn it off with
   `/sorm autolaunch off` or the window's Auto-launch toggle.
2. Makes a box of a tank class Main Tank and Main Assist, and checks that everyone is in
   the zone, alive and at the giver.
3. Records each toon's current mode, sets the MA to SicTank and the rest to Chase, and
   zones the group in.
4. Inside, starts the event. When the mission is done, each toon goes back to the mode it
   had before the start.

The script only acts inside a `*_mission` zone. Holding the task in the live zone does
nothing.

## Commands

The command is `/sormissions`. MacroQuest accepts any unique start of a command, so
`/sorm` works too, and is what the rest of this page uses. `/sorm help` lists them all.
The main ones:

| Command | Does |
|---|---|
| `/sorm start [force]` | Start the current mission (from outside: the group zones in first) |
| `/sorm pause [on\|off]` | Pause this toon's script |
| `/sorm ma` | Toggle MA mode (the group's Main Assist role turns it on by itself) |
| `/sorm burn [on\|off\|now\|reset]` | Shar'Drahn / Colossus burn mode |
| `/sorm wax [balance\|kill]` | Waxwork: balance the adds' HP, or kill in order |
| `/sorm illusion skel\|jann\|other` | Echo: illusion item (other = players handle it) |
| `/sorm circle [on\|off\|now]` | Shar'Drahn: this toon runs into Storm Calls |
| `/sorm autolaunch [on\|off]` | Start the script on boxes that do not answer the start's check |
| `/sorm set_use_eqbc on\|off` | Group commands over EQBC instead of DanNet |
| `/sorm debug [on\|off]` | Debug output |
