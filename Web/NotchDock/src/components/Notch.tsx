"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { AnimatePresence, LayoutGroup, motion, useReducedMotion } from "framer-motion";
import { Activity, ArrowUpRight, Check, ChevronUp, FileText, RotateCcw, Volume2, VolumeX, X } from "lucide-react";
import ChatView from "./ChatView";
import LiveActivitiesView from "./LiveActivitiesView";
import ZoopMascot from "./ZoopMascot";
import NotchStatus from "./NotchStatus";
import useCompletionAlerts from "./useCompletionAlerts";
import { chime, makePlan, type Message, type Mood, type Task } from "@/lib/demo";

const spring = { type: "spring" as const, stiffness: 300, damping: 28, mass: .8 };
const STORAGE = "zoop-notch-demo-v1";
interface Flight { id: string; taskId: string; x: number; y: number; endX: number; endY: number; }
interface Props { open: boolean; setOpen: (open: boolean) => void; onTasksChange: (tasks: Task[]) => void; }

export default function Notch({ open, setOpen, onTasksChange }: Props) {
  const [view, setView] = useState<"chat" | "activities">("chat");
  const [messages, setMessages] = useState<Message[]>([]);
  const [tasks, setTasks] = useState<Task[]>([]);
  const [thinking, setThinking] = useState(false);
  const [draft, setDraft] = useState("");
  const [ready, setReady] = useState(false);
  const [sound, setSound] = useState(true);
  const [flights, setFlights] = useState<Flight[]>([]);
  const [pulse, setPulse] = useState(0);
  const [selected, setSelected] = useState<string | null>(null);
  const alerts = useCompletionAlerts(tasks, ready, open, sound);
  const liveButton = useRef<HTMLButtonElement>(null);
  const notch = useRef<HTMLDivElement>(null);
  const replyTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const streamTimers = useRef(new Map<string, ReturnType<typeof setInterval>>());
  const sendLock = useRef(false);
  const dispatchLock = useRef(new Set<string>());
  const reduced = useReducedMotion();

  useEffect(() => {
    try {
      const saved = JSON.parse(localStorage.getItem(STORAGE) || "null");
      if (saved && Array.isArray(saved.messages) && Array.isArray(saved.tasks)) {
        const validTasks = saved.tasks.filter((t: Task) => typeof t.id === "string" && typeof t.prompt === "string" && Array.isArray(t.steps) && ["keyboards", "travel", "research"].includes(t.kind) && ["pending", "dispatching", "running", "paused", "complete", "cancelled"].includes(t.status) && Number.isFinite(t.progress));
        setMessages(saved.messages.filter((m: Message) => typeof m.id === "string" && typeof m.text === "string" && ["user", "assistant"].includes(m.role)).map((m: Message) => ({ ...m, stream: undefined })));
        // Restoring an executing demo pauses it; no work starts implicitly after refresh.
        setTasks(validTasks.map((t: Task) => ({ ...t, status: ["dispatching", "running"].includes(t.status) ? "paused" : t.status })));
        if (typeof saved.sound === "boolean") setSound(saved.sound);
      }
    } catch { /* A blocked storage API or stale cache should not prevent using the demo. */ }
    setReady(true);
    const timers = streamTimers.current;
    return () => { if (replyTimer.current) clearTimeout(replyTimer.current); timers.forEach(clearInterval); timers.clear(); };
  }, []);

  // Persist complete message sources, without writing storage on every streamed token.
  const persistedMessages = JSON.stringify(messages.slice(-120).map(({ stream, ...message }) => { void stream; return message; }));
  useEffect(() => {
    if (!ready) return;
    try { localStorage.setItem(STORAGE, JSON.stringify({ messages: JSON.parse(persistedMessages), tasks: tasks.slice(-40), sound })); } catch { /* The demo remains usable when browser storage is full. */ }
  }, [persistedMessages, tasks, sound, ready]);
  useEffect(() => { onTasksChange(tasks); }, [tasks, onTasksChange]);
  useEffect(() => {
    const keyboard = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
      if ((e.metaKey || e.ctrlKey) && e.key === "k") { e.preventDefault(); setOpen(true); setView("chat"); }
    };
    window.addEventListener("keydown", keyboard); return () => window.removeEventListener("keydown", keyboard);
  }, [setOpen]);

  useEffect(() => {
    if (!open) return;
    const dismissOutside = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Element) || notch.current?.contains(target)) return;
      // Dedicated Zoop buttons handle their own toggle/open action on click.
      if (target.closest("[data-zoop-trigger]")) return;
      setOpen(false);
    };
    document.addEventListener("pointerdown", dismissOutside, true);
    return () => document.removeEventListener("pointerdown", dismissOutside, true);
  }, [open, setOpen]);

  const streaming = messages.some(m => m.stream);
  const streamingReply = messages.some(m => m.stream && !m.id.startsWith("done-"));
  const running = tasks.filter(t => t.status === "running" || t.status === "dispatching");
  const hasRunning = running.some(t => t.status === "running");
  const count = tasks.filter(t => t.status === "running" || t.status === "paused").length;
  const mood: Mood = alerts.celebrating ? "done" : running.length ? "cooking" : thinking || streamingReply ? "thinking" : "sleeping";
  const status = running.length ? `${running[0].progress < 28 ? "searching" : "cooking"}: ${running[0].domain.split("/")[0].split(" · ")[0]}` : thinking ? "thinking…" : streamingReply ? "putting it into words…" : count ? "taking a breather" : "idling";
  const compactStatus = running.length ? running[0].progress < 28 ? "searching" : "cooking" : thinking ? "thinking" : streamingReply ? "writing" : count ? "paused" : "idling";
  const orbActive = Boolean(running.length || thinking || streamingReply);

  const streamReply = useCallback((message: Message, task?: Task) => {
    let textChars = 0;
    let planChars = 0;
    const planLength = task?.steps.join("\n").length || 0;
    setMessages(previous => [...previous, { ...message, stream: { textChars, planChars } }]);
    const timer = setInterval(() => {
      if (textChars < message.text.length) textChars = Math.min(message.text.length, textChars + (reduced ? 12 : 3));
      else planChars = Math.min(planLength, planChars + (reduced ? 12 : 4));
      const complete = textChars === message.text.length && planChars === planLength;
      setMessages(previous => previous.map(m => m.id === message.id ? { ...m, stream: complete ? undefined : { textChars, planChars } } : m));
      if (complete) { clearInterval(timer); streamTimers.current.delete(message.id); sendLock.current = false; }
    }, 26);
    streamTimers.current.set(message.id, timer);
  }, [reduced]);

  useEffect(() => {
    if (!hasRunning) return;
    const timer = setInterval(() => setTasks(previous => previous.map(task => task.status === "running" ? { ...task, progress: Math.min(100, task.progress + 4), status: task.progress + 4 >= 100 ? "complete" : "running" } : task)), 1200);
    return () => clearInterval(timer);
  }, [hasRunning]);
  useEffect(() => {
    const unannounced = tasks.filter(t => t.status === "complete" && !messages.some(m => m.id === `done-${t.id}`));
    if (!unannounced.length) return;
    unannounced.forEach(t => streamReply({ id: `done-${t.id}`, role: "assistant", text: `All done! I put your comparison together in ${t.file}. You can save the report from Live Activities or the exports folder on your desktop.` }));
  }, [tasks, messages, streamReply]);

  function send(text: string) {
    if (sendLock.current || streaming) return;
    sendLock.current = true;
    setMessages(previous => [...previous, { id: crypto.randomUUID(), role: "user", text }]);
    setThinking(true);
    const pending = [...tasks].reverse().find(t => t.status === "pending");
    replyTimer.current = setTimeout(() => {
      const greeting = /^(hi|hello|hey|thanks|thank you)[!.\s]*$/i.test(text);
      const help = /^(what can you do|how does this work|help)[?.!\s]*$/i.test(text);
      if (greeting || help) {
        streamReply({ id: crypto.randomUUID(), role: "assistant", text: greeting ? "Hey, I’m Zoop. What’s on your mind? Give me a little research, a comparison, or a trip to plan. I’ll show you my plan before I start." : "I can simulate research, compare keyboards or work tools, and plan a weekend away. Tell me what you need. You’ll approve the plan, then watch me work in a separate little desk. All research and prices in this preview are sample data." });
      } else {
        const refinement = pending && /^(also|only|make|keep|under|include|instead|focus|actually|can you add|change|budget)/i.test(text);
        const plan = makePlan(text, refinement ? pending : undefined);
        setTasks(previous => [...previous.map(t => refinement && t.id === pending.id ? { ...t, status: "cancelled" as const } : t), plan]);
        streamReply({ id: crypto.randomUUID(), role: "assistant", text: refinement ? "Got it. I’ve adjusted the plan with that in mind. Here’s what I’ll do:" : "Of course. I’ll take a look in my own little workspace, while you keep doing your thing. Here’s the plan:", taskId: plan.id }, plan);
      }
      setThinking(false);
    }, reduced ? 100 : 850);
  }

  function start(id: string, button: HTMLButtonElement) {
    if (dispatchLock.current.has(id) || tasks.find(t => t.id === id)?.status !== "pending") return;
    dispatchLock.current.add(id);
    const origin = button.getBoundingClientRect();
    const target = liveButton.current?.getBoundingClientRect();
    if (!target) { dispatchLock.current.delete(id); return; }
    setTasks(previous => previous.map(t => t.id === id ? { ...t, status: "dispatching" } : t));
    setFlights(previous => [...previous, { id: crypto.randomUUID(), taskId: id, x: origin.x + origin.width / 2 - 56, y: origin.y + origin.height / 2 - 20, endX: target.x + target.width / 2 - 56, endY: target.y + target.height / 2 - 20 }]);
    chime(sound);
  }
  function arrive(flight: Flight) {
    setFlights(previous => previous.filter(f => f.id !== flight.id));
    setTasks(previous => previous.map(t => t.id === flight.taskId && t.status === "dispatching" ? { ...t, status: "running" } : t));
    setSelected(flight.taskId); setPulse(previous => previous + 1);
  }
  function control(id: string, action: "pause" | "resume" | "stop") {
    setTasks(previous => previous.map(t => t.id === id ? { ...t, status: action === "pause" ? "paused" : action === "resume" ? "running" : "cancelled" } : t));
  }
  function viewTask(id: string) { setSelected(id); setView("activities"); setOpen(true); alerts.dismiss(); }
  function reset() {
    if (replyTimer.current) clearTimeout(replyTimer.current);
    streamTimers.current.forEach(clearInterval); streamTimers.current.clear();
    setMessages([]); setTasks([]); setFlights([]); setThinking(false); setDraft(""); alerts.reset(); setSelected(null); setView("chat");
    sendLock.current = false; dispatchLock.current.clear();
  }

  return <LayoutGroup id="zoop">
    <div ref={notch} className={`notch-anchor ${alerts.active ? "has-completion" : ""}`} onPointerDownCapture={alerts.recordInteraction} onPointerMoveCapture={alerts.recordInteraction} onKeyDownCapture={alerts.recordInteraction} onWheelCapture={alerts.recordInteraction}>
      <div className="notch-frame" style={{ width: open ? "min(820px, 94vw)" : "min(376px, 94vw)", height: open ? `min(${view === "activities" ? 488 : 520}px, calc(100dvh - 100px))` : 34 }}>
        <motion.div aria-hidden="true" layout layoutId="notch-surface" className={`notch-surface ${open ? "is-expanded liquid-glass" : "is-collapsed"} ${running.length ? "is-working" : ""}`} style={{ borderBottomLeftRadius: open ? 28 : 18, borderBottomRightRadius: open ? 28 : 18 }} transition={spring}/>
          {open ? <motion.div key="expanded" className="drawer-content" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0, transition: { duration: .1 } }} transition={{ duration: .25, delay: .12 }}>
            <header className="drawer-header">
              <div className="companion-identity"><motion.div layoutId="companion" transition={spring}><ZoopMascot size={32} mood={mood}/></motion.div><div><strong>zoop<span>®</span></strong><NotchStatus label={status} active={orbActive}/></div></div>
              <div className="header-actions"><motion.button ref={liveButton} key={pulse} className={`live-button ${view === "activities" ? "active" : ""}`} onClick={() => setView(view === "activities" ? "chat" : "activities")} animate={pulse && !reduced ? { scale: [1, 1.15, 1] } : { scale: 1 }} transition={{ duration: .4 }}><Activity size={13}/><span>Live Activities</span><span className={`activity-counter ${count ? "has-count" : ""}`}>{count}</span></motion.button><button className="minimize-button" onClick={() => setOpen(false)} aria-label="Minimize Zoop"><ChevronUp size={17}/></button></div>
            </header>
            <AnimatePresence mode="wait" initial={false}><motion.div className="drawer-view" key={view} initial={{ opacity: 0, y: 5 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -4 }} transition={{ duration: .16 }}>{view === "chat" ? <ChatView messages={messages} tasks={tasks} thinking={thinking} streaming={streaming} draft={draft} onDraftChange={setDraft} onSend={send} onStart={start} onViewTask={viewTask}/> : <LiveActivitiesView tasks={tasks} selected={selected} onSelect={setSelected} onBack={() => setView("chat")} onControl={control}/>}</motion.div></AnimatePresence>
          </motion.div> : <motion.button key="collapsed" className="collapsed-button" aria-label="Open Zoop" onClick={() => setOpen(true)} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: .12, delay: .1 }}><span className="compact-companion"><motion.span layoutId="companion" transition={spring}><ZoopMascot size={30} mood={mood}/></motion.span><AnimatePresence>{running.length > 0 && <motion.span key="working-count" className="working-count" role="status" aria-label={`${running.length} ${running.length === 1 ? "task" : "tasks"} working`} initial={{ opacity: 0, scale: .8 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: .8 }}><motion.span className="working-count-number" key={running.length} initial={reduced ? false : { opacity: 0, y: 3 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: .18 }}>{running.length}</motion.span><span>working</span></motion.span>}</AnimatePresence></span><NotchStatus label={compactStatus} active={orbActive} compact/></motion.button>}
      </div>
      <div className="hardware-notch" aria-hidden="true"><div className="camera-lens"/></div>
      <AnimatePresence>{open && <motion.div className="drawer-underbar" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ delay: .2 }}><span>YOUR EXTRA PAIR OF HANDS</span><div><button onClick={() => setSound(v => !v)} aria-label={sound ? "Mute sounds" : "Enable sounds"} title={sound ? "Mute sounds" : "Enable sounds"}>{sound ? <Volume2 size={12}/> : <VolumeX size={12}/>}</button><button onClick={reset} aria-label="Reset demo" title="Reset demo"><RotateCcw size={11}/></button></div></motion.div>}</AnimatePresence>
      <AnimatePresence mode="wait">{alerts.active && <motion.div key={alerts.active.id} className={`completion-toast liquid-glass ${alerts.speaking ? "is-speaking" : ""}`} role="status" aria-live="polite" aria-atomic="true" initial={reduced ? { opacity: 0 } : { y: -16, scale: .92, opacity: 0 }} animate={{ y: 0, scale: 1, opacity: 1 }} exit={{ y: -8, scale: .97, opacity: 0 }} transition={spring}>
        <button data-zoop-trigger className="completion-open" onClick={() => viewTask(alerts.active!.id)} aria-label={`View completed task: ${alerts.active.title}`}>
          <span className="toast-icon"><Check size={17}/></span>
          <span className="completion-copy"><span className="completion-eyebrow">A LITTLE WIN <span>JUST FINISHED</span></span><strong>{alerts.active.title}</strong><span className="completion-detail">Your report is ready. Take a look <ArrowUpRight size={10}/></span></span>
        </button>
        <button className="completion-dismiss" onClick={alerts.dismissCurrent} aria-label="Dismiss task notification"><X size={12}/></button>
        {alerts.pending > 1 && <span className="completion-queued">+{alerts.pending - 1} more ready</span>}
        <motion.div className="completion-lifetime" initial={{ scaleX: 1 }} animate={{ scaleX: 0 }} transition={{ duration: 7, ease: "linear" }} aria-hidden="true"/>
      </motion.div>}</AnimatePresence>
    </div>
    <AnimatePresence>{flights.map(flight => <motion.div key={flight.id} className="flying-ticket" style={{ left: flight.x, top: flight.y }} initial={{ x: 0, y: 0, scale: 1, rotate: -4, opacity: 1 }} animate={{ x: [0, (flight.endX - flight.x) * .35, flight.endX - flight.x], y: [0, Math.min(-70, flight.endY - flight.y - 45), flight.endY - flight.y], rotate: [-4, -14, 8], scale: [1, 1.08, .15], opacity: [1, 1, .1] }} transition={{ duration: reduced ? .05 : .8, times: [0, .48, 1], ease: [0.33, 0, .22, 1] }} onAnimationComplete={() => arrive(flight)}><FileText size={15}/><span>on my way</span><ArrowUpRight size={12}/></motion.div>)}</AnimatePresence>
  </LayoutGroup>;
}
