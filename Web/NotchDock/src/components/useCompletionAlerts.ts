"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { playCompletionAudio, primeCompletionAudio } from "@/lib/completion-audio";
import type { Task } from "@/lib/demo";

export default function useCompletionAlerts(tasks: Task[], ready: boolean, open: boolean, sound: boolean) {
  const [queue, setQueue] = useState<Task[]>([]);
  const [celebrating, setCelebrating] = useState(false);
  const [speaking, setSpeaking] = useState(false);
  const seen = useRef<Set<string> | null>(null);
  const lastInteraction = useRef(0);
  const wasOpen = useRef(open);
  const soundRef = useRef(sound);
  const stopVoice = useRef<(() => void) | null>(null);
  const active = queue[0] ?? null;
  soundRef.current = sound;

  const recordInteraction = useCallback(() => {
    lastInteraction.current = Date.now();
    if (soundRef.current) primeCompletionAudio();
  }, []);
  const dismiss = useCallback(() => {
    stopVoice.current?.();
    setQueue([]);
    setCelebrating(false);
  }, []);
  const dismissCurrent = useCallback(() => setQueue(previous => previous.slice(1)), []);

  useEffect(() => {
    if (open && !wasOpen.current) { lastInteraction.current = Date.now(); dismiss(); }
    wasOpen.current = open;
  }, [open, dismiss]);

  useEffect(() => {
    if (!ready) return;
    // Restored history never speaks or generates a fresh completion alert.
    if (!seen.current) {
      seen.current = new Set(tasks.filter(t => t.status === "complete").map(t => t.id));
      return;
    }
    const finished = tasks.filter(t => t.status === "complete" && !seen.current!.has(t.id));
    finished.forEach(t => seen.current!.add(t.id));
    const away = !open || document.visibilityState === "hidden" || !document.hasFocus() || Date.now() - lastInteraction.current >= 15_000;
    if (away && finished.length) setQueue(previous => [...previous, ...finished]);
  }, [tasks, ready, open]);

  useEffect(() => {
    if (!active) return;
    setCelebrating(true);
    const expression = setTimeout(() => setCelebrating(false), 1800);
    if (soundRef.current) stopVoice.current = playCompletionAudio(playing => {
      setSpeaking(playing);
      setCelebrating(playing);
      if (playing) clearTimeout(expression);
    });
    const retirement = setTimeout(dismissCurrent, 7000);
    return () => {
      clearTimeout(expression); clearTimeout(retirement);
      stopVoice.current?.(); stopVoice.current = null;
      setCelebrating(false);
    };
  }, [active, dismissCurrent]);

  useEffect(() => { if (!sound) stopVoice.current?.(); }, [sound]);

  const reset = useCallback(() => { dismiss(); seen.current = new Set(); }, [dismiss]);
  return { active, pending: queue.length, celebrating, speaking, recordInteraction, dismiss, dismissCurrent, reset };
}
