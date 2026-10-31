"use client";

import { useCallback, useState } from "react";
import { MotionConfig } from "framer-motion";
import Desktop from "@/components/Desktop";
import Notch from "@/components/Notch";
import type { Task } from "@/lib/demo";

export default function Home() {
  const [open, setOpen] = useState(true);
  const [tasks, setTasks] = useState<Task[]>([]);
  const updateTasks = useCallback((next: Task[]) => setTasks(next), []);
  return <MotionConfig reducedMotion="user"><Desktop open={open} onToggle={() => setOpen(value => !value)} tasks={tasks}><Notch open={open} setOpen={setOpen} onTasksChange={updateTasks}/></Desktop></MotionConfig>;
}
