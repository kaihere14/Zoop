"use client";

import { useEffect, useState } from "react";
import { motion, AnimatePresence, useReducedMotion } from "framer-motion";
import { Check, ChevronLeft, ChevronRight, LockKeyhole, RotateCw, Search, Sparkles } from "lucide-react";
import { getRows, type Task } from "@/lib/demo";
import { ThinkingOrb } from "./ui/thinking-orb";

export default function GhostDesk({ task }: { task: Task }) {
  const [row, setRow] = useState(0);
  const [click, setClick] = useState(false);
  const reduced = useReducedMotion();
  const active = task.status === "running";
  const rows = getRows(task.kind);
  useEffect(() => {
    if (!active) return;
    const timer = setInterval(() => { setRow(v => (v + 1) % 3); setClick(true); }, 2300);
    return () => clearInterval(timer);
  }, [active]);
  useEffect(() => { if (!click) return; const timeout = setTimeout(() => setClick(false), 700); return () => clearTimeout(timeout); }, [click, row]);
  const currentStep = Math.min(2, Math.floor(task.progress / 34));

  return <div className="ghost-desk">
    <div className="browser-chrome"><div className="traffic-lights"><i/><i/><i/></div><div className="browser-navigation"><ChevronLeft size={12}/><ChevronRight size={12}/></div><div className="browser-address"><LockKeyhole size={10}/><span>{task.domain.split(" · ")[0]}</span><RotateCw size={10}/></div><span className="browser-tabs">＋</span></div>
    <div className="browser-page">
      <div className="research-nav"><span className="research-brand">{task.kind === "keyboards" ? <>RTINGS<span>.com</span></> : task.kind === "travel" ? <>somewhere<span> good.</span></> : <>the<span> shortlist.</span></>}</span><span>REVIEWS <span className="nav-slash">/</span> {task.kind === "keyboards" ? "KEYBOARDS" : task.kind === "travel" ? "GETAWAYS" : "WORKSPACE"}</span><Search size={12}/></div>
      <div className="research-heading"><div><span className="research-eyebrow">A LITTLE RESEARCH GOES A LONG WAY</span><h3>{task.kind === "keyboards" ? "Good keys. Great company." : task.kind === "travel" ? "A change of scenery." : "Tools for a calmer workday."}</h3><p>{task.kind === "keyboards" ? "Three mechanical keyboards worth making space for." : task.kind === "travel" ? "Three places to slow down and stay a while." : "Less busywork. More room for the work you love."}</p></div><span className="research-count">03<span>shortlisted</span></span></div>
      <div className="comparison-table" role="table" aria-label="Simulated research comparison">
        <div className="comparison-head" role="row"><span>THE SHORTLIST</span><span>{task.kind === "keyboards" ? "LATENCY" : "RATING"}</span><span>{task.kind === "travel" ? "PER NIGHT" : "PRICE"}</span></div>
        {rows.map((item, i) => <div key={item.name} className={`comparison-row ${row === i && active ? "row-highlight" : ""}`} role="row">
          <div className="comparison-product"><div className={`product-art product-art-${task.kind} art-${i}`}>{task.kind === "keyboards" ? <div className="keyboard-art">{Array.from({ length: 24 }, (_, k) => <i key={k}/>)}</div> : task.kind === "travel" ? <span>⌂</span> : <span>{item.name[0]}</span>}</div><div><strong>{item.name}</strong><span>{item.detail}</span></div></div><span className="metric">{item.metric}</span><strong className="price">{item.price}<Check size={10}/></strong>
        </div>)}
      </div>
      <div className="browser-footnote"><span><Sparkles size={10}/> Collected with a little care</span><span>Illustrative data · Web simulation</span></div>
      <motion.div className="ghost-pointer" aria-hidden="true" animate={{ left: `${[68, 78, 73][row]}%`, top: `${[47, 63, 80][row]}%`, opacity: active ? 1 : .35 }} transition={reduced ? { duration: 0 } : { type: "spring", stiffness: 75, damping: 19 }}>
        <svg width="20" height="25" viewBox="0 0 22 28"><path d="M2 2v21l5-5 5 8 4-2-5-8 8-1L2 2Z" fill="#b6f542" stroke="#384c1d" strokeWidth="1.5"/></svg><span>zoop</span>
        <AnimatePresence>{click && active && !reduced && <motion.i className="click-ripple" initial={{ scale: .2, opacity: .8 }} animate={{ scale: 3, opacity: 0 }} exit={{ opacity: 0 }} transition={{ duration: .65 }}/>}</AnimatePresence>
      </motion.div>
    </div>
    <div className="desk-status">{active ? <ThinkingOrb preset={task.progress < 28 ? "searching" : "working"} tone="ghost" size="sm" showLabel={false} className="desk-orb"/> : <span className="status-dot"/>}<span>{task.status === "complete" ? "Research complete. Your file is ready." : task.status === "paused" ? "Taking a breather. Resume whenever you’re ready." : task.status === "cancelled" ? "Task stopped. Your desktop is untouched." : ["Reading reviews and gathering the good bits…", "Comparing the details, one at a time…", "Putting the finishing touches on your report…"][currentStep]}</span><span>{task.progress}%</span></div>
    <div className="desk-progress"><motion.div animate={{ width: `${task.progress}%` }} transition={{ duration: .8 }}/></div>
  </div>;
}
