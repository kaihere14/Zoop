"use client";

import { motion, useReducedMotion } from "framer-motion";
import type { Mood } from "@/lib/demo";

const body = [
  "................", ".........LL.....", "........LL......", ".....GGGGGG.....",
  "...GGGGGGGGGG...", "..GGGGGGGGGGGG..", "..GGGGGGGGGGGG..", ".GGGGGGGGGGGGGG.",
  ".GGGGGGGGGGGGGG.", ".GGGGGGGGGGGGGG.", ".GGGGGGGGGGGGGG.", "..GGGGGGGGGGGG..",
  "...GGGGGGGGGG...", "....GGGGGGGG....", "....GG....GG....", "................",
];

export default function ZoopMascot({ mood = "idle", size = 40 }: { mood?: Mood; size?: number }) {
  const reduced = useReducedMotion();
  const sleeping = mood === "sleeping";
  return <motion.svg width={size} height={size} viewBox="0 0 16 16" shapeRendering="crispEdges" role="img" aria-label={`Zoop is ${mood}`} className="zoop-mascot"
    animate={reduced ? { y: 0, scaleY: 1, rotate: 0 } : { y: sleeping ? [0, .4, 0] : mood === "cooking" ? [0, -1.5, 0] : [0, -.6, 0], scaleY: sleeping ? [1, .97, 1] : 1, rotate: mood === "done" ? [0, -8, 8, 0] : 0 }}
    transition={{ duration: sleeping ? 4 : mood === "cooking" ? .8 : 3, repeat: Infinity, ease: "easeInOut" }}>
    {body.flatMap((row, y) => [...row].map((pixel, x) => pixel !== "." && <rect key={`${x}-${y}`} x={x} y={y} width="1" height="1" fill={pixel === "L" ? "#d5ff8d" : "#b6f542"} />))}
    <motion.g fill="#1c2c0b" animate={!reduced && mood === "idle" ? { scaleY: [1, 1, .1, 1, 1] } : { x: mood === "thinking" ? [0, 1, 0, -1, 0] : 0 }} style={{ transformOrigin: "8px 8px" }} transition={{ duration: mood === "thinking" ? 2.5 : 4.5, repeat: Infinity }}>
      {sleeping ? <path d="M3 7h1v1h2V7h1v1H6v1H4V8H3zm6 0h1v1h2V7h1v1h-1v1h-2V8H9z"/> : <><path d="M4 6h2v3H4z"/>{mood === "done" ? <path d="M10 7h3v1h-3z"/> : <path d="M10 6h2v3h-2z"/>}</>}
    </motion.g>
    {mood === "cooking" || mood === "done" ? <><path d="M6 10h1v1h2v-1h1v2H6z" fill="#1c2c0b"/><path d="M3 9h2v1H3zm8 0h2v1h-2z" fill="#f39a86" opacity=".8"/></> : <path d="M7 10h2v1H7z" fill="#1c2c0b"/>}
    {sleeping && <motion.path className="sleep-z" aria-hidden="true" d="M13 0h3v1h-1v1h-1v1h2v1h-3V3h1V2h1V1h-2z" fill="#d5ff8d" animate={reduced ? { opacity: .6 } : { opacity: [.2, .75, .2], y: [0, -1, -2] }} transition={{ duration: 4, repeat: Infinity, ease: "easeInOut" }}/>}
  </motion.svg>;
}
