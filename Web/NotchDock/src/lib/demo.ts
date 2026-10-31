export type Mood = "idle" | "sleeping" | "thinking" | "cooking" | "done";
export type TaskStatus = "pending" | "dispatching" | "running" | "paused" | "complete" | "cancelled";
export type TaskKind = "keyboards" | "travel" | "research";
export interface Task {
  id: string;
  prompt: string;
  title: string;
  domain: string;
  file: string;
  steps: string[];
  kind: TaskKind;
  status: TaskStatus;
  progress: number;
}
export interface Message {
  id: string; role: "user" | "assistant"; text: string; taskId?: string;
  stream?: { textChars: number; planChars: number };
}
export interface DeskRow { name: string; detail: string; metric: string; price: string; tag?: string; }

export const suggestions = [
  { label: "Find my next keyboard", prompt: "Research mechanical keyboards on RTINGS and compare prices under $200.", icon: "keyboard" },
  { label: "Plan a weekend away", prompt: "Find a quiet weekend getaway near San Francisco and compare three places to stay.", icon: "travel" },
  { label: "Research an idea", prompt: "Research the best productivity tools for a small design studio and make a comparison.", icon: "research" },
] as const;

export function makePlan(prompt: string, context?: Task): Task {
  const input = context ? `${context.prompt} ${prompt}` : prompt;
  const kind: TaskKind = /keyboard|switch|keycap/i.test(input) ? "keyboards" : /weekend|travel|trip|hotel|getaway/i.test(input) ? "travel" : "research";
  const title = kind === "keyboards" ? "Find your next keyboard" : kind === "travel" ? "A little weekend escape" : "Research your idea";
  return {
    id: crypto.randomUUID(), prompt: input, title, kind,
    domain: kind === "keyboards" ? "rtings.com/keyboards" : kind === "travel" ? "travel.google.com" : "notion.so · linear.app · readwise.io",
    file: kind === "keyboards" ? "mechanical_keyboards.md" : kind === "travel" ? "weekend_getaway.md" : "research_notes.md",
    steps: kind === "keyboards" ? ["Explore RTINGS reviews and shortlist three keyboards", "Compare typing feel, latency, and current prices", "Put a tidy comparison in your exports folder"]
      : kind === "travel" ? ["Explore three peaceful stays near San Francisco", "Compare location, nightly rates, and the little extras", "Save your shortlist and a simple weekend itinerary"]
      : ["Explore the tools and gather the useful details", "Compare features, pricing, and the best fit", "Bring the findings together in a concise report"],
    status: "pending", progress: 0,
  };
}

export function getRows(kind: TaskKind): DeskRow[] {
  if (kind === "keyboards") return [
    { name: "Keychron Q1 Max", detail: "75% · Gateron Jupiter Brown", metric: "3.2 ms", price: "$179", tag: "Best overall" },
    { name: "NuPhy Air75 V2", detail: "75% · Low profile · Wireless", metric: "5.1 ms", price: "$119", tag: "For your desk" },
    { name: "Wooting 60HE+", detail: "60% · Hall effect · Wired", metric: "0.8 ms", price: "$175", tag: "Fastest" },
  ];
  if (kind === "travel") return [
    { name: "A cabin in Point Reyes", detail: "Coastal trails · 1.5 hours away", metric: "4.9 / 5", price: "$189", tag: "Our pick" },
    { name: "A hideaway in Mendocino", detail: "Ocean views · 3 hours away", metric: "4.8 / 5", price: "$225", tag: "Ocean air" },
    { name: "A cottage in Sonoma", detail: "Garden terrace · 1 hour away", metric: "4.7 / 5", price: "$165", tag: "Close to home" },
  ];
  return [
    { name: "Notion", detail: "A home for notes, docs, and projects", metric: "9.1 / 10", price: "$10", tag: "All together" },
    { name: "Linear", detail: "Keep projects moving with less effort", metric: "9.4 / 10", price: "$8", tag: "Our pick" },
    { name: "Readwise Reader", detail: "Save the good stuff. Find it again.", metric: "8.8 / 10", price: "$10", tag: "Deep work" },
  ];
}

export function reportFor(task: Task) {
  const rows = getRows(task.kind);
  return `# ${task.title}\n\n> Zoop Phase 1 simulation. All listings, scores, availability, and prices below are illustrative sample data, not live research.\n\n## Your request\n${task.prompt}\n\n## Comparison\n\n| Option | Details | ${task.kind === "keyboards" ? "Latency" : "Rating"} | Sample price | Note |\n| --- | --- | --- | --- | --- |\n${rows.map(r => `| ${r.name} | ${r.detail} | ${r.metric} | ${r.price} | ${r.tag} |`).join("\n")}\n\n## Recommendation\n${rows.find(r => /pick|overall/.test(r.tag || ""))?.name || rows[0].name} is the suggested starting point in this sample comparison. Verify current details before deciding.\n\nPrepared in Zoop’s simulated isolated desk.\n`;
}

export function downloadReport(task: Task) {
  const url = URL.createObjectURL(new Blob([reportFor(task)], { type: "text/markdown;charset=utf-8" }));
  const anchor = document.createElement("a");
  anchor.href = url; anchor.download = task.file; anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

let audio: AudioContext | undefined;
export function chime(enabled: boolean) {
  if (!enabled) return;
  try {
    audio ??= new AudioContext();
    void audio.resume();
    const tone = audio.createOscillator();
    const gain = audio.createGain();
    tone.type = "sine";
    tone.frequency.setValueAtTime(880, audio.currentTime);
    tone.frequency.exponentialRampToValueAtTime(1320, audio.currentTime + .13);
    gain.gain.setValueAtTime(.0001, audio.currentTime);
    gain.gain.exponentialRampToValueAtTime(.065, audio.currentTime + .015);
    gain.gain.exponentialRampToValueAtTime(.0001, audio.currentTime + .3);
    tone.connect(gain); gain.connect(audio.destination);
    tone.start(); tone.stop(audio.currentTime + .32);
  } catch { /* Audio is an enhancement; browser audio restrictions must not block dispatch. */ }
}
