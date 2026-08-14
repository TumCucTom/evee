# Quiet Voice Instrument Design

Date: 2026-08-14

Tracking: TOM-52

Status: Approved direction; awaiting written-spec review

## Outcome

Evee should feel like a refined native voice instrument rather than a collection of stock SwiftUI screens. The redesign keeps every existing journey and safety boundary intact while introducing a coherent visual system, a custom shell, and restrained motion tied to genuine capture state.

Success means a new user can immediately identify the current voice state, the primary action, and the relationship between workspace records without sacrificing keyboard access, VoiceOver clarity, reduced-motion behavior, small-window usability, or light/dark contrast.

## Scope

This work changes presentation and interaction styling for:

- The main window shell and navigation
- Onboarding and model readiness
- Library, search, record rows, and record detail
- Meeting and memo capture surfaces
- Settings information architecture
- Menu bar presentation and floating capture HUD
- Empty, loading, recovery, warning, and failure states

It does not change transcription models, capture semantics, persistence formats, integration behavior, privacy defaults, or product terminology. Existing safety-critical actions continue to call the same store operations.

## Product Principles

### Quiet until voice matters

The canvas, navigation, and passive content remain neutral. Saturated colour and motion are reserved for capture, processing, selection, and primary decisions.

### Native, not generic

The app retains native macOS windowing, focus, keyboard behavior, controls, and split-view resizing. Custom composition replaces the visual defaults that currently make the interface look like a prototype.

### State before decoration

Every animated or coloured element communicates real state. The signature voice element responds to measured microphone level, capture phase, or deterministic progress. It never simulates voice activity.

### Dense but breathable

Metadata remains compact while major sections gain stronger rhythm and negative space. Repeated outlines and nested cards are removed where hierarchy can be expressed through alignment, spacing, and surface tone.

## Visual System

### Colour roles

The implementation will expose semantic roles rather than screen-specific colours:

| Role | Light intent | Dark intent |
|---|---|---|
| Canvas | Warm near-white | Deep neutral graphite |
| Sidebar | Slightly cooler quiet layer | Slightly lifted graphite |
| Surface | White document surface | Neutral raised surface |
| Elevated surface | White with restrained depth | Higher-luminance raised surface |
| Hairline | Low-contrast warm grey | Low-contrast cool grey |
| Primary text | Near-black ink | Soft near-white |
| Secondary text | Neutral grey | Muted cool grey |
| Tertiary text | Quiet metadata grey | Quiet metadata grey |
| Accent | Electric violet | Brighter accessible violet |
| Spectral accent | Blue to violet to magenta | Lightened blue to violet to magenta |
| Success, warning, destructive | Accessible semantic colours | Accessible semantic colours |

The spectral gradient appears only in the product mark, the active voice thread, primary capture actions, and rare attention boundaries. Ordinary cards, navigation, and controls do not use it.

### Typography roles

All text uses system typography with explicit semantic roles:

- Display: 30–34 pt, bold, slightly tightened
- Page title: 21–24 pt, bold or heavy
- Section title: 13–15 pt, semibold
- Body: 13–14 pt, regular
- Metadata: 10–12 pt, medium where needed
- Transcript timestamp: 9–10 pt monospaced, semibold
- Button label: 12–13 pt, semibold

Views consume these roles rather than defining ad-hoc sizes. Dynamic Type and system accessibility scaling remain supported where macOS provides them.

### Spacing, shape, and depth

- Base spacing steps: 4, 8, 12, 16, 24, and 32 points
- Compact controls: 8–10 point continuous corners
- Panels: 14–18 point continuous corners
- Pills and status chips: capsule geometry
- Hairlines replace most full card outlines
- Shadows are limited to floating, selected, or modal surfaces
- Important content aligns to a consistent readable measure rather than filling every available pixel

### Motion

Motion has four semantic timings:

- Press and hover response: 100–140 ms
- Selection and local state change: 180–220 ms
- Route or panel transition: 220–280 ms
- Voice-thread settlement: one controlled spring around 360 ms

Transitions use opacity, two-to-four-point translation, scale changes no larger than two percent, and shape interpolation. There is no perpetual ambient animation while idle. Reduce Motion removes springs and spatial movement, retaining immediate state and short opacity changes only where useful.

## Signature Voice Thread

`VoiceThread` is Evee’s ownable visual element. It is a thin spectral line or compact waveform made from a small number of smooth lobes. It has four modes:

- Idle: static, quiet, low-saturation line
- Listening or recording: amplitude follows normalized real microphone level
- Processing: a restrained highlight travels along a static line
- Complete or protected: the line settles into a short resolved mark

The component accepts presentation state and normalized level as values. It contains no timers or capture logic. A motion policy chooses animated or immediate transitions from the environment’s Reduce Motion setting.

The thread appears consistently in the app mark, onboarding illustration, capture HUD, page-level capture status, and relevant empty states. Scale and detail vary by context, but its geometry and state language remain recognisable.

## Shell and Navigation

The main window continues to use native split-view behavior, but the sidebar content becomes custom-composed:

- A compact brand header with the voice-thread mark
- Purposeful navigation items with label, symbol, optional count, hover, focus, and selected states
- A calm selected capsule rather than the default full-row list highlight
- A bottom status module showing Ready, Listening, Recording, Processing, Protected, or Needs attention
- Shortcut help revealed contextually rather than occupying a permanent equal-weight block

The content region uses a shared `EveePageHeader` for title, concise supporting copy, status, and primary actions. Route changes use a restrained fade/translation transition while preserving native selection and focus behavior.

## Primary Journeys

### Onboarding

Onboarding becomes a two-zone composition on spacious windows:

- An atmospheric left field containing the brand, outcome copy, and large voice thread
- A focused right readiness panel that presents permissions and model readiness in order

The compact layout stacks the same regions in a scroll view. Completed steps collapse visually but remain understandable. Download progress, cancellation, failure, and retry transition within one stable row so controls do not jump unpredictably. The first incomplete action receives keyboard focus according to the existing presentation model.

### Workspace and library

The library uses a strong page header, an integrated search field, and mostly borderless rows. Each row presents title, useful snippet, kind, source, and time with clear selection and hover depth. Kind colour appears as a small glyph or marker rather than colouring the whole card.

Empty states use a quiet voice thread, one helpful sentence, and one relevant next action. Recovery remains prominent but becomes a distinct status panel rather than another generic card.

### Record detail

Record detail becomes a readable document canvas:

- Editable title and compact metadata chips at the top
- Transcript or note content at a comfortable measure
- Extracted overview sections with explicit evidence hierarchy
- Retained-audio controls grouped as one transport surface
- A sticky or consistently placed action bar for save, export, and delete

Speaker-label editing, playback, evidence links, and destructive confirmations keep their current behavior and accessibility meaning.

### Meetings and memos

When idle, the primary capture action and privacy promise lead. During capture, the voice thread and elapsed state become the visual anchor. Audio-source health, live transcript, title, and notes follow in descending importance.

Warnings remain unmistakable but no longer dominate healthy sessions. Processing retains navigation freedom and shows a calm local-progress state. Memo recording uses the same capture language at a smaller scale.

### Settings

Settings is reorganised into a category rail and one focused settings panel. Categories map to the existing groups, such as Voice, Writing, Meetings, Privacy and storage, and Integrations. Selecting a category changes presentation only; bindings and save behavior remain unchanged.

Each panel uses clear subsection headings, aligned labels, short supporting copy, and responsive rows. Advanced integration and recovery controls remain available but do not compete visually with everyday voice settings. Keyboard traversal follows the visible order and remains contained within native controls.

### Capture HUD and menu bar

The floating HUD becomes compact and state-shaped:

- Recording: live voice thread, concise action/status copy, elapsed context where available
- Processing: quiet travelling highlight and local-processing label
- Delivering: direct destination-focused label
- Protected or failed: static shield or warning state with unambiguous next step

The HUD remains non-activating and screen-sharing protected. Actions that require focus stay in the menu bar or main app. The menu bar presentation adopts the same state chip, voice thread, spacing, and button hierarchy without becoming visually elaborate.

## Component Boundaries

The visual system is composed from small, reusable units:

- `EveeColors`, `EveeTypography`, `EveeSpacing`, `EveeShape`, and `EveeMotion`
- `VoiceThread`
- `EveeNavigationItem`
- `EveePageHeader`
- `EveePrimaryButton` and supporting secondary/destructive styles
- `EveePanel`
- `EveeStatusChip`
- `EveeEmptyState`
- `EveeSearchField`
- `EveeSettingsCategoryRail`

These components accept values and actions; they do not reach into `AppStore`. Journey views translate store state into presentation values. This keeps visual code independently testable and avoids duplicating product logic.

## State and Data Flow

Existing `AppStore` state remains authoritative. Journey views derive a small visual presentation model:

1. Capture, permission, model, recovery, or record state changes in `AppStore`.
2. The view maps it to semantic visual state such as idle, active, processing, success, warning, or failure.
3. Shared components render colour, iconography, copy, and allowed motion for that state.
4. User actions call the existing store methods.

Microphone amplitude is clamped and normalised before reaching `VoiceThread`. Missing or stale level data renders a low static recording line rather than fabricated movement.

## Error, Recovery, and Privacy Presentation

- Failures keep explicit text, a non-colour icon, and a direct recovery action.
- Recovery and protected states are visually distinct from success.
- Permission denial surfaces the appropriate system-settings action without implying access was granted.
- Privacy mode continues to replace sensitive content rather than merely obscuring it.
- Screen-sharing protection remains installed for every Evee-owned window and the floating HUD.
- The redesign does not expose private record contents in thumbnails, decorative previews, or screenshots.

## Accessibility

- Every custom control exposes an explicit accessibility label, hint where useful, and selected or status value.
- Focus rings remain visible at a minimum two-point visual weight.
- Colour is never the only state cue.
- Text and essential controls meet WCAG AA contrast in both appearances.
- Keyboard order follows spatial order across sidebar, page header, content, and action bar.
- Reduce Motion behavior is defined for every animated component.
- The shell remains usable at the existing minimum window size and at narrower settings layouts.
- VoiceOver announcements remain driven by deduplicated product state, not visual animation frames.

## Verification

### Automated

- Token contrast tests for light and dark semantic pairs
- Voice-thread state and level-normalisation tests
- Motion-policy tests for Reduce Motion
- Navigation and settings-category presentation-state tests
- Existing onboarding, capture, recovery, accessibility, and lifecycle suites
- Full Swift test suite and app build

### Visual and physical

- Packaged app reviewed in light and dark appearances
- Minimum-size and expanded-window layouts
- Keyboard-only traversal of onboarding, navigation, settings, meeting, and record detail
- VoiceOver labels and state announcements
- Reduce Motion review of capture, processing, route, and selection changes
- Real microphone-level response during dictation, memo, and meeting capture
- HUD visibility over external apps without stealing focus
- Screenshot review of onboarding, empty workspace, populated workspace, record detail, active meeting, settings, menu bar, and HUD

All visual evidence is kept outside the repository unless it contains only synthetic, non-private fixture data and is intentionally approved for inclusion.

## Acceptance Criteria

- The app has one coherent visual hierarchy across every primary journey.
- The active voice state is the strongest visual signal without becoming distracting.
- No major screen relies on a stock sidebar list, undifferentiated form, or repeated generic card treatment as its primary composition.
- The spectral accent remains rare and meaningful.
- Motion reflects real state, stays restrained, and respects Reduce Motion.
- Light and dark appearances both pass contrast and visual review.
- Existing behavior, privacy boundaries, capture reliability, recovery semantics, keyboard access, and VoiceOver output do not regress.
- The exact packaged artifact passes the affected physical Mac journeys before merge.
