"use client";

import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { ArrowDownToLine, ArrowLeft, Check, CircleStop, Pause, Play, ShieldCheck } from "lucide-react";
import GhostDesk from "./GhostDesk";
import ZoopMascot from "./ZoopMascot";
import { downloadReport, type Task } from "@/lib/demo";

interface Props { tasks: Task[]; selected: string | null; onSelect: (id: string) => void; onBack: () => void; onControl: (id: string, action: "pause" | "resume" | "stop") => void; }

export default function LiveActivitiesView({ tasks, selected, onSelect, onBack, onControl }: Props) {
  const reduced = useReducedMotion();
  const active = tasks.filter(t => t.status === "running" || t.status === "paused");
  const [tabs, setTabs] = useState<Task[]>(active);
  const previousActive = useRef(new Set(active.map(t => t.id)));
  const departureTimers = useRef(new Map<string, ReturnType<typeof setTimeout>>());
  const task = tasks.find(t => t.id === selected && ["running", "paused", "complete"].includes(t.status))
    || active[active.length - 1] || [...tasks].reverse().find(t => t.status === "complete");

  useEffect(() => {
    const running = tasks.filter(t => t.status === "running" || t.status === "paused");
    const finished = tasks.filter(t => t.status === "complete" && previousActive.current.has(t.id));
    const timers = departureTimers.current;
    finished.forEach(t => {
      timers.set(t.id, setTimeout(() => {
        timers.delete(t.id);
        setTabs(previous => previous.filter(tab => tab.id !== t.id));
      }, reduced ? 0 : 600));
    });
    previousActive.current = new Set(running.map(t => t.id));
    setTabs(tasks.filter(t => t.status === "running" || t.status === "paused" || (t.status === "complete" && timers.has(t.id))));
    if (finished.some(t => t.id === selected) && running.length) onSelect(running[running.length - 1].id);
  }, [tasks, selected, onSelect, reduced]);

  useEffect(() => {
    const timers = departureTimers.current;
    return () => { timers.forEach(clearTimeout); timers.clear(); };
  }, []);

  return <div className="activities-view">
    <div className="activities-toolbar"><button className="back-button" onClick={onBack}><ArrowLeft size={13}/>Back to chat</button><span><ShieldCheck size={12}/> A desk of my own</span></div>
    {!task ? <div className="empty-activities"><ZoopMascot size={60}/><h2>A little quiet here.</h2><p>Give me a task in chat. I’ll get to work right here.</p><button className="start-button" onClick={onBack}>Let’s find something to do <ArrowLeft size={13}/></button></div> : <>
      <motion.div className="task-tabs" aria-label="Tasks" initial={false} animate={{ height: tabs.length ? 32 : 0 }} transition={reduced ? { duration: 0 } : { type: "spring", stiffness: 300, damping: 30, mass: .7 }}>
        <AnimatePresence initial={false}>{tabs.map(t => <motion.div key={t.id} className="task-tab-slot" layout initial={{ width: 0, opacity: 0, scale: .96 }} animate={{ width: "auto", opacity: 1, scale: 1 }} exit={reduced ? { width: 0, opacity: 0, paddingRight: 0 } : { width: 0, opacity: 0, y: -7, scale: .92, filter: "blur(5px)", paddingRight: 0 }} transition={{ duration: reduced ? 0 : .36, ease: [.22, 1, .36, 1], layout: { type: "spring", stiffness: 300, damping: 30 } }}>
          <motion.button data-task-id={t.id} data-status={t.status} className={`task-tab ${t.id === task.id ? "selected" : ""} ${t.status === "complete" ? "task-tab-complete" : ""}`} onClick={() => onSelect(t.id)} animate={!reduced && t.status === "complete" ? { scale: [1, 1.025, 1] } : { scale: 1 }} transition={{ duration: .35 }}><span className={`status-dot ${t.status === "running" ? "pulse" : ""}`}/><span>{t.status === "running" ? "cooking" : t.status === "complete" ? "done" : "paused"}: {t.domain.split(" · ")[0]}</span>{t.status === "complete" && <Check size={11}/>}</motion.button>
        </motion.div>)}</AnimatePresence>
      </motion.div>
      <GhostDesk key={task.id} task={task}/>
      <div className="activity-footer"><span><span className="isolation-icon">↗</span> Separate session. Zero interruptions.</span><div>{task.status === "complete" ? <button className="download-button" onClick={() => downloadReport(task)}><ArrowDownToLine size={12}/>Save report</button> : task.status !== "cancelled" ? <><button className="task-control" onClick={() => onControl(task.id, task.status === "paused" ? "resume" : "pause")}>{task.status === "paused" ? <Play size={12}/> : <Pause size={12}/>}<span>{task.status === "paused" ? "Resume" : "Pause"}</span></button><button className="task-control stop-control" onClick={() => onControl(task.id, "stop")}><CircleStop size={12}/><span>Stop</span></button></> : <span className="muted">Task stopped</span>}</div></div>
    </>}
  </div>;
}
