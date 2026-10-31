let context: AudioContext | undefined;
let clip: Promise<AudioBuffer> | undefined;

// Resume on a real Zoop interaction so the voice can play later, in the background.
export function primeCompletionAudio() {
  try {
    context ??= new AudioContext();
    void context.resume().catch(() => {});
    clip ??= fetch("/audio/completion.mp3")
      .then(response => { if (!response.ok) throw new Error("Audio unavailable"); return response.arrayBuffer(); })
      .then(data => context!.decodeAudioData(data));
    void clip.catch(() => { clip = undefined; });
  } catch { /* The completion card still works without audio. */ }
}

export function playCompletionAudio(onPlaying: (playing: boolean) => void) {
  let cancelled = false;
  let source: AudioBufferSourceNode | undefined;
  if (context && clip) {
    void clip.then(buffer => {
      if (cancelled || !context || context.state !== "running") return;
      source = context.createBufferSource();
      source.buffer = buffer;
      source.connect(context.destination);
      source.onended = () => { source?.disconnect(); onPlaying(false); };
      source.start();
      onPlaying(true);
    }).catch(() => { /* A blocked audio device must not prevent notification delivery. */ });
  }
  return () => {
    cancelled = true;
    if (source) { source.onended = null; source.stop(); source.disconnect(); }
    onPlaying(false);
  };
}
