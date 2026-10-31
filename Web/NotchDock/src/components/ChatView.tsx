"use client";

import { useEffect, useLayoutEffect, useRef } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { ArrowUp, ArrowUpRight, Check, CornerDownLeft, FileText, Globe2, Keyboard, MapPin, Search, Sparkles } from "lucide-react";
import ZoopMascot from "./ZoopMascot";
import { ThinkingOrb } from "./ui/thinking-orb";
import { suggestions, type Message, type Task } from "@/lib/demo";

interface Props {
  messages: Message[]; tasks: Task[]; thinking: boolean; streaming: boolean;
  draft: string; onDraftChange: (value: string) => void;
  onSend: (value: string) => void;
  onStart: (id: string, button: HTMLButtonElement) => void;
  onViewTask: (id: string) => void;
}

export default function ChatView({ messages, tasks, thinking, streaming, draft, onDraftChange, onSend, onStart, onViewTask }: Props) {
  const scroller = useRef<HTMLDivElement>(null);
  const messageList = useRef<HTMLDivElement>(null);
  const pinned = useRef(true);
  const initialized = useRef(false);
  const input = useRef<HTMLInputElement>(null);
  const hasMessages = messages.length > 0;
  useLayoutEffect(() => {
    const element = scroller.current;
    if (!element) return;
    if (!initialized.current && messages.length) {
      initialized.current = true;
      pinned.current = true;
    }
    if (pinned.current) element.scrollTop = element.scrollHeight;
  }, [messages, thinking, streaming]);
  useLayoutEffect(() => {
    const element = scroller.current;
    if (!element) return;
    const followLatest = () => { if (pinned.current) element.scrollTop = element.scrollHeight; };
    const observer = new ResizeObserver(followLatest);
    observer.observe(element);
    if (messageList.current) observer.observe(messageList.current);
    const frame = requestAnimationFrame(followLatest);
    return () => { observer.disconnect(); cancelAnimationFrame(frame); };
  }, [hasMessages]);
  useEffect(() => {
    const focus = (e: KeyboardEvent) => { if ((e.metaKey || e.ctrlKey) && e.key === "k") { e.preventDefault(); input.current?.focus(); } };
    window.addEventListener("keydown", focus); return () => window.removeEventListener("keydown", focus);
  }, []);
  function submit(e: React.FormEvent) { e.preventDefault(); if (draft.trim() && !thinking && !streaming) { pinned.current = true; onSend(draft.trim()); onDraftChange(""); } }

  return <div className="chat-view">
    <div ref={scroller} className={`chat-scroll ${messages.length ? "has-messages" : ""}`} onScroll={e => { const el = e.currentTarget; pinned.current = el.scrollHeight - el.scrollTop - el.clientHeight < 64; }}>
      {!messages.length ? <motion.div className="welcome" initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: .15 }}>
        <div className="welcome-mascot"><ZoopMascot size={54}/><span className="sparkle-one">✦</span><span className="sparkle-two">✧</span></div>
        <h1>A little help.<br/><span>A lot more headspace.</span></h1>
        <p>Hand me the busywork. Make room for your thing.</p>
        <div className="suggestions">
          {suggestions.map((item, i) => {
            const Icon = [Keyboard, MapPin, Search][i];
            return <button key={item.label} onClick={() => { pinned.current = true; onSend(item.prompt); }} className="suggestion"><Icon size={16}/><span>{item.label}</span><ArrowUpRight size={13}/></button>;
          })}
        </div>
      </motion.div> : <div ref={messageList} className="message-list" role="log" aria-label="Conversation with Zoop" aria-live="polite">
        <AnimatePresence initial={false}>{messages.map(message => {
          const task = tasks.find(t => t.id === message.taskId);
          const textComplete = !message.stream || message.stream.textChars >= message.text.length;
          const planComplete = !message.stream || message.stream.planChars >= (task?.steps.join("\n").length || 0);
          return <motion.article className={`message message-${message.role}`} key={message.id} aria-busy={Boolean(message.stream)} initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }}>
            {message.role === "assistant" && <div className="message-avatar"><ZoopMascot size={25} mood={task?.status === "complete" ? "done" : "idle"}/></div>}
            <div className="message-content">
              {message.role === "assistant" && <div className="message-byline"><span className="message-name">Zoop <span>your extra pair of hands</span></span>{message.stream && <ThinkingOrb preset="solving" tone="ghost" size="sm" showLabel={false} label="Writing a response" className="stream-orb"/>}</div>}
              <p className="message-text">{message.stream ? message.text.slice(0, message.stream.textChars) : message.text}{message.stream && !textComplete && <span className="stream-cursor" aria-hidden="true"/>}</p>
              {task && textComplete && <motion.div className="plan-card" initial={message.stream ? { opacity: 0, y: 5 } : false} animate={{ opacity: 1, y: 0 }} transition={{ duration: .2 }}>
                <div className="plan-title"><span className="plan-icon"><Globe2 size={15}/></span><div><strong>{task.title}</strong><span>{task.domain}</span></div><span className="plan-label">THE PLAN</span></div>
                <ol>{task.steps.map((step, i) => {
                  const offset = task.steps.slice(0, i).join("\n").length + (i ? 1 : 0);
                  const chars = message.stream ? Math.max(0, message.stream.planChars - offset) : step.length;
                  if (!chars && message.stream) return null;
                  return <li key={step}><span>{String(i + 1).padStart(2, "0")}</span><span className="plan-step-text">{step.slice(0, chars)}{chars < step.length && <span className="stream-cursor" aria-hidden="true"/>}</span></li>;
                })}</ol>
                {planComplete && <div className="plan-destination"><FileText size={13}/><span>~/Zoop/exports/<b>{task.file}</b></span></div>}
                {planComplete ? <div className="plan-action">
                  {task.status === "pending" ? <><span>Can I start now?</span><button className="start-button" onClick={e => onStart(task.id, e.currentTarget)}>Start Process <ArrowUpRight size={14}/></button></>
                    : task.status === "cancelled" ? <span className="muted">This plan was cancelled.</span>
                    : <><span className="plan-accepted"><Check size={13}/>{task.status === "complete" ? "All wrapped up" : "On it. Your desk is still yours."}</span><button className="text-button" onClick={() => onViewTask(task.id)}>View activity <ArrowUpRight size={13}/></button></>}
                </div> : <div className="plan-stream-status"><ThinkingOrb preset="working" tone="ghost" size="sm" label="A plan is coming together" className="plan-writing-orb"/></div>}
              </motion.div>}
            </div>
          </motion.article>;
        })}</AnimatePresence>
        <AnimatePresence>{thinking && <motion.div className="thinking-message" initial={{ opacity: 0, y: 4 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}><ThinkingOrb preset="thinking" tone="ghost" size="md" label="Thinking it through" className="zoop-thinking-orb"/></motion.div>}</AnimatePresence>
      </div>}
    </div>
    <div className="composer-wrap">
      <form className="composer" onSubmit={submit}>
        <Sparkles size={17} className="composer-sparkle"/>
        <input ref={input} value={draft} onChange={e => onDraftChange(e.target.value)} placeholder="What can I take off your plate?" aria-label="Message Zoop" maxLength={1200} autoComplete="off"/>
        <span className="input-shortcut">⌘ K</span>
        <button className="send-button" aria-label="Send message" disabled={!draft.trim() || thinking || streaming} type="submit"><ArrowUp size={17}/></button>
      </form>
      <div className="composer-footnote"><span><span className="status-dot"/> Your cursor stays yours.</span><span>Enter to send <CornerDownLeft size={10}/></span></div>
    </div>
  </div>;
}
