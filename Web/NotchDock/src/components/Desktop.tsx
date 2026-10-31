"use client";

import { useEffect, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { ArrowDownToLine, ArrowUpRight, BatteryFull, Check, Command, FileText, Folder, Maximize2, Minimize2, Search, Settings2, ShieldCheck, Wifi, X } from "lucide-react";
import ZoopMascot from "./ZoopMascot";
import { downloadReport, type Task } from "@/lib/demo";

type Panel = "finder" | "notes" | "about" | "settings" | null;
interface Props { children: React.ReactNode; open: boolean; onToggle: () => void; tasks: Task[]; }

export default function Desktop({ children, open, onToggle, tasks }: Props) {
  const [now, setNow] = useState<Date | null>(null);
  const [panel, setPanel] = useState<Panel>(null);
  const [notes, setNotes] = useState("Make a little room.\n\nThe good ideas tend to show up when you have a moment to think.\n\nLet Zoop take care of the busywork. This space is yours.");
  const [fullscreen, setFullscreen] = useState(false);
  const [wallpaper, setWallpaper] = useState<"dusk" | "forest">("dusk");
  useEffect(() => {
    setNow(new Date());
    const timer = setInterval(() => setNow(new Date()), 1000);
    try { const saved = localStorage.getItem("zoop-desktop-note"); if (saved) setNotes(saved); } catch { /* Optional browser storage. */ }
    const sync = () => setFullscreen(Boolean(document.fullscreenElement));
    document.addEventListener("fullscreenchange", sync);
    return () => { clearInterval(timer); document.removeEventListener("fullscreenchange", sync); };
  }, []);
  const done = tasks.filter(t => t.status === "complete");
  function editNotes(value: string) { setNotes(value); try { localStorage.setItem("zoop-desktop-note", value); } catch { /* Optional browser storage. */ } }
  async function toggleFullscreen() { try { if (document.fullscreenElement) await document.exitFullscreen(); else await document.documentElement.requestFullscreen(); } catch { /* Fullscreen may be unavailable in an embedded preview. */ } }
  function togglePanel(next: Panel) { setPanel(previous => previous === next ? null : next); }

  return <main className={`desktop wallpaper-${wallpaper}`}>
    <div className="wallpaper" aria-hidden="true"/><div className="wallpaper-grain" aria-hidden="true"/>
    <header className="mac-menubar"><div className="menu-left"><button className="apple-button" onClick={() => togglePanel("about")} aria-label="About this demo"><svg width="14" height="17" viewBox="0 0 16 19" fill="currentColor"><path d="M11.7 3.1c.7-.9.6-2 .6-2s-1.2.1-2 .9c-.9.9-.8 2-.8 2s1.3.1 2.2-.9ZM13.5 10c0-1.9 1.5-2.9 1.6-3-1-1.4-2.6-1.6-3.2-1.6-1.4-.1-2.8.8-3.5.8s-1.8-.8-3-.8C3.8 5.4 2.3 6.4 1.5 7.8 0 10.5 1.1 14.5 2.6 16.7c.7 1 1.6 2.1 2.8 2 1.1 0 1.6-.7 3-.7s1.9.7 3.1.7 2-1 2.7-2c.8-1.2 1.2-2.4 1.2-2.5-.1 0-2-.8-2-4.2Z" transform="translate(0 -1)"/></svg></button><button className="finder-menu" onClick={() => togglePanel("finder")}>Finder</button><button className="optional-menu" onClick={() => togglePanel("finder")}>File</button><button className="optional-menu" onClick={() => togglePanel("notes")}>Edit</button><button className="optional-menu" onClick={() => togglePanel("settings")}>View</button><button className="optional-menu" onClick={() => togglePanel("about")}>Help</button></div><div className="menu-right"><span className="menu-battery"><BatteryFull size={20}/></span><Wifi size={15}/><button data-zoop-trigger onClick={onToggle} aria-label="Find Zoop"><Search size={14}/></button><button onClick={() => togglePanel("settings")} aria-label="Desktop settings"><Settings2 size={14}/></button><time suppressHydrationWarning>{now ? now.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" }) : "Sat Oct 31"}<span className="menu-time">{now ? now.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" }) : "2:30 PM"}</span></time></div></header>
    {children}
    <div className="desktop-brand"><div className="desktop-wordmark">zoop<span>®</span></div><div className="brand-rule"/><p>Your Mac has<br/>room for two<span>.</span></p><span className="brand-caption">YOU DO YOUR THING. I’LL DO MINE.</span></div>
    <div className="desktop-files"><button className="desktop-file" onClick={() => togglePanel("finder")}><div className="folder-icon"><Folder size={45} strokeWidth={1.3}/>{done.length > 0 && <span>{done.length}</span>}</div><span>Zoop exports</span></button><button className="desktop-file" onClick={() => togglePanel("notes")}><div className="note-icon"><span/><i/><i/><i/></div><span>A little headspace</span></button></div>
    <div className="desktop-bottom"><div className="prototype-label"><span className="status-dot"/> INTERACTIVE PREVIEW <span className="prototype-version">/ 0.1</span></div><button className="fullscreen-button" onClick={toggleFullscreen}>{fullscreen ? <Minimize2 size={12}/> : <Maximize2 size={12}/>}<span>{fullscreen ? "Exit fullscreen" : "Try it fullscreen"}</span></button></div>
    <div className="dock-wrap"><nav className="mac-dock" aria-label="Desktop dock"><button className={`dock-app finder-app ${panel === "finder" ? "app-active" : ""}`} aria-label="Open exports in Finder" onClick={() => togglePanel("finder")}><span className="finder-face">⌣</span><span className="dock-tooltip">Finder</span></button><button className={`dock-app notes-app ${panel === "notes" ? "app-active" : ""}`} aria-label="Open Notes" onClick={() => togglePanel("notes")}><span/><i/><i/><i/><span className="dock-tooltip">Notes</span></button><div className="dock-divider"/><button className={`dock-app zoop-app ${open ? "app-active" : ""}`} aria-label={open ? "Hide Zoop drawer" : "Show Zoop drawer"} data-zoop-trigger onClick={onToggle}><ZoopMascot size={36} mood={tasks.some(t => t.status === "running" || t.status === "dispatching") ? "cooking" : "sleeping"}/><span className="dock-tooltip">Zoop</span></button><button className={`dock-app settings-app ${panel === "settings" ? "app-active" : ""}`} aria-label="Open settings" onClick={() => togglePanel("settings")}><Settings2 size={27}/><span className="dock-tooltip">Settings</span></button></nav></div>
    <AnimatePresence>{!open && !panel && <motion.button className="notch-hint" initial={{ opacity: 0, y: -5 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} data-zoop-trigger onClick={onToggle}><span>↑</span>A little help is up here.<kbd>⌘ K</kbd></motion.button>}</AnimatePresence>
    <AnimatePresence>{panel && <motion.section className={`desktop-window window-${panel}`} role="dialog" aria-label={panel === "finder" ? "Zoop exports" : panel === "notes" ? "Notes" : panel === "settings" ? "Desktop settings" : "About Zoop"} initial={{ opacity: 0, y: 15, scale: .96 }} animate={{ opacity: 1, y: 0, scale: 1 }} exit={{ opacity: 0, y: 8, scale: .97 }} transition={{ type: "spring", stiffness: 300, damping: 28 }}>
      <div className="window-titlebar"><button className="window-close" onClick={() => setPanel(null)} aria-label="Close window"><X size={9}/></button><span>{panel === "finder" ? "Zoop exports" : panel === "notes" ? "A little headspace" : panel === "settings" ? "Make yourself at home" : "Hello, I’m Zoop."}</span><div/></div>
      {panel === "finder" ? <div className="exports-content"><div className="exports-location"><Folder size={15}/>~/Zoop/exports/</div>{!done.length ? <div className="exports-empty"><Folder size={38} strokeWidth={1}/><h3>Good things are on their way.</h3><p>Finished reports will land here.<br/>Start a task with Zoop to make your first one.</p><button className="start-button" onClick={() => { setPanel(null); if (!open) onToggle(); }}>Say hello to Zoop <ArrowUpRight size={13}/></button></div> : done.map(t => <div className="export-file" key={t.id}><FileText size={25}/><div><strong>{t.file}</strong><span>Markdown · Sample report</span></div><button aria-label={`Download ${t.file}`} onClick={() => downloadReport(t)}><ArrowDownToLine size={16}/></button></div>)}</div>
        : panel === "notes" ? <textarea className="notes-editor" aria-label="Your personal note" value={notes} onChange={e => editNotes(e.target.value)} spellCheck={false}/>
        : panel === "settings" ? <div className="settings-content"><h3>A different kind of desktop.</h3><p>Set the mood. The rest can wait.</p><div className="wallpaper-options"><button className={`wallpaper-swatch swatch-dusk ${wallpaper === "dusk" ? "chosen" : ""}`} onClick={() => setWallpaper("dusk")}>{wallpaper === "dusk" && <Check size={17}/>}<span>After hours</span></button><button className={`wallpaper-swatch swatch-forest ${wallpaper === "forest" ? "chosen" : ""}`} onClick={() => setWallpaper("forest")}>{wallpaper === "forest" && <Check size={17}/>}<span>Quiet morning</span></button></div><button className="settings-fullscreen" onClick={toggleFullscreen}><Maximize2 size={15}/>{fullscreen ? "Leave fullscreen" : "Enter fullscreen"}<ArrowUpRight size={14}/></button><div className="settings-shortcut"><Command size={13}/> + K <span>Bring Zoop into focus</span></div></div>
        : <div className="about-content"><ZoopMascot size={70}/><h2>Your Mac has room for two.</h2><p>A little companion that takes care of the busywork, so you can stay in your flow.</p><div><ShieldCheck size={15}/><span>This is an interactive web simulation. Tasks and research use illustrative sample data. No desktop control or real websites are automated.</span></div><small>ZOOP · PHASE 01 · MADE FOR A LITTLE HEADSPACE</small></div>}
    </motion.section>}</AnimatePresence>
  </main>;
}
