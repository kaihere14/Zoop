# Zoop · Notch Dock

Phase 1: a self-contained, local Next.js 15 / React 19 / Tailwind CSS 3 / Framer Motion prototype. No native macOS code or backend is included.

```sh
cd Web/NotchDock
npm install
npm run dev
```

Open **http://localhost:3000**. Node.js 20 or newer is recommended.

## Try the full interaction

1. Choose a suggestion or type a request. Zoop proposes a plan; nothing runs until you click **Start Process**.
2. Watch the response and plan steps stream in. The [B6 UI thinking orb](https://ui.armandev.space/r/thinking-orb.json) appears while Zoop thinks, writes, searches, and works; it is adapted to Tailwind 3 and the shared Framer Motion runtime. Approve the finished plan. A ticket flies from the button into **Live Activities**, accompanied by a synthesized chime.
3. Open **Live Activities** to watch the isolated browser and ghost pointer. Pause, resume, or stop the task.
4. After about 30 seconds of active time, the task tab briefly shows a checkmark, then blurs, fades, and folds away. Remaining tabs slide together. Download the Markdown report from the activity or the desktop **Zoop exports** folder; completed reports stay available there, without accumulating in the live tab row.
5. Continue chatting to launch another task. Tasks can run concurrently. Short refinements beginning with “only”, “also”, “include”, etc. revise the latest unapproved plan.

Click outside the drawer or click the chevron to collapse it. Click the notch or dock mascot to reopen it, and use **⌘/Ctrl K** to open chat. **Escape** also collapses Zoop. The collapsed status pairs the thinking orb with labels that blur and fade as states change; tasks continue while the drawer is closed. The sound toggle and reset control sit just below the drawer. Desktop Notes are editable, settings switch the wallpaper, and fullscreen is available in browsers that permit it.

Chat, tasks, sound preference, and Notes are stored locally in this browser. Reloading pauses running tasks; resume them explicitly in Live Activities. Reset clears chat and tasks. Browser storage failure does not prevent the demo from working.

While working, the notch always uses the same searching globe orb; only the status words change. When idle or finished, it simply says “idling” and the orb disappears. Zoop sleeps with closed eyes, gentle breathing, and a little floating pixel Z. The dock mascot sleeps too. Reopening chat jumps straight to the latest message without replaying old message animations. The glass morphs on a separate background layer so the conversation stays sharp.

## Scope

Conversation is a deterministic demo with three scenarios: keyboards, travel, and productivity-tool research. It is not connected to an AI model. All sites, cursor movement, prices, scores, and progress are simulated. Export paths illustrate the intended native destination; **Save report** uses the browser’s normal Downloads location. Reports clearly identify sample data.

The wallpaper and mascot are original local SVG assets. There are no remote image, font, or audio dependencies. The camera cutout is 160 × 34 px; the collapsed activity wings extend beyond the hardware bezel. Chat is 820 × 520 px; the compact Live Activities drawer is 488 px high. Both are constrained to the available viewport. Motion respects reduced-motion preferences.

## Files

```text
src/app/page.tsx                 Desktop entry point
src/app/layout.tsx               Metadata and document shell
src/app/globals.css              Desktop, glass, responsive styling
src/components/Notch.tsx         Shared-layout morph, state, ticket flight, audio
src/components/NotchStatus.tsx   Larger status orb and spring, blur, fade word transitions
src/components/ChatView.tsx      Conversation, plan approval, fixed composer
src/components/LiveActivitiesView.tsx  Task selection and controls
src/components/GhostDesk.tsx     Simulated browser, table, autonomous pointer
src/components/ZoopMascot.tsx    Animated 16 × 16 SVG pixel renderer
src/components/Desktop.tsx      Menu bar, dock, Notes, exports, settings
src/lib/demo.ts                 Typed scenarios, reports, Web Audio chime
tailwind.config.ts              Liquid-glass gradients, colors, filters
```

## Verification

```sh
npm run typecheck
npm run build
npx playwright install chromium
npm run test:e2e
```

Browser tests cover approval gating, ticket arrival, task pause/resume/stop, report download, multi-turn plan refinement, reload persistence, desktop controls, and viewport containment on desktop and mobile. When testing in a container, set `PLAYWRIGHT_BROWSERS_PATH` to the browser installation directory for both install and test commands.

Native production architecture and moving components into the main app structure are deferred until the web motion and aesthetic are approved.
