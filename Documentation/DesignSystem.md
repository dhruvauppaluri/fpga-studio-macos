# FPGA Studio Experience System

FPGA Studio follows native macOS interaction patterns and uses progressive disclosure so a first-time FPGA learner and an experienced hardware designer can work in the same application.

## Principles

1. **One clear next action.** The learning guide recommends one safe action at a time: Check, Simulate, Build, Detect, Program SRAM.
2. **Concept before tool name.** User-facing capability labels lead with outcomes. Individual executable names live in expanded toolchain details and logs.
3. **Safe by default.** Blinky and SystemVerilog are the default first project. SRAM is the primary programming action. Persistent flash and experimental hard blocks are advanced.
4. **No hidden capability.** Guided mode changes presentation, not project behavior or file formats. Every advanced feature remains reachable.
5. **Native and calm.** Use system typography, semantic colors, materials, controls, keyboard behavior, and accessibility settings. Avoid decorative motion and proprietary Apple assets.

## Tokens

- Typography: San Francisco through SwiftUI semantic styles; SF Mono through the system monospaced design.
- Color: system accent, label, secondary label, text background, control background, and semantic red/orange/green.
- Spacing: 8 pt compact, 12 pt standard, 20 pt roomy.
- Corners: 14 pt learning/content cards; system defaults for controls and sheets.
- Motion: no required animation; all workflows remain understandable with Reduce Motion enabled.

## Progressive levels

### Guided, default

- First-run three-page tour.
- Blinky selected by default and labeled as the recommended first project.
- Next-step guide visible above the editor.
- Capability-based toolchain status.
- Beginner-safe synthesis summary.
- Persistent flash inside an Advanced menu.

### Advanced, optional

- Experimental backend notice and hard-block controls visible in the inspector.
- Raw build logs, project manifest, pin assignments, and all programming actions remain available in both levels.

## Core components

### Learning guide

States: Validate, Simulate, Build, Connect, Program SRAM, Complete. It shows an icon, action-oriented title, one-sentence explanation, progress, and one primary button. It can be dismissed and restored in Settings.

### Capability row

Shows what the user can do—simulate, build, or program—followed by Ready or the missing capability. Individual tool paths and versions are disclosed separately.

### Safety confirmation

Persistent flash confirmation names the board and exact artifact, shows timestamp, size, and digest, explains power/switch requirements, and requires an explicit acknowledgement. The destructive phase cannot be cancelled.

### Empty state

Every empty state says what the area is, why it is empty, and the action that fills it. Avoid generic “No data” language.

## Accessibility

- All icon-only buttons have labels and help text.
- Primary workflows are keyboard accessible through menus and standard shortcuts.
- Status never relies on color alone; icons and text accompany semantic color.
- Touch targets use native control sizing.
- Text remains selectable in technical detail views.
- No task depends on animation, translucency, or pointer hover.
