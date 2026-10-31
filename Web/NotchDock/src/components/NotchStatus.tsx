"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { ThinkingOrb } from "./ui/thinking-orb";

interface Props {
  label: string;
  active: boolean;
  compact?: boolean;
}

export default function NotchStatus({ label, active, compact = false }: Props) {
  const reduced = useReducedMotion();
  const idling = label === "idling";

  return <div className={`notch-status ${compact ? "collapsed-status" : "expanded-status"} ${idling ? "is-idling" : ""}`} role="status" aria-live="polite" aria-atomic="true" aria-label={label}>
    {!idling && <motion.div className="status-orb-shell" animate={{ opacity: active ? 1 : .72, scale: 1 }} transition={{ duration: reduced ? 0 : .3 }}>
      <ThinkingOrb preset="searching" kind="globe" active={active} speed={.8} tone="ghost" size="sm" showLabel={false} className="notch-orb" aria-hidden="true" aria-live="off" role="presentation"/>
    </motion.div>}
    <span className="status-label-viewport">
      <AnimatePresence initial={false} mode="sync">
        <motion.span className="status-label" key={label}
          initial={reduced ? { opacity: 0 } : { opacity: 0, y: 10, filter: "blur(8px)", scale: .96 }}
          animate={{ opacity: 1, y: 0, filter: "blur(0px)", scale: 1 }}
          exit={reduced ? { opacity: 0 } : { opacity: 0, y: -9, filter: "blur(7px)", scale: .97, transition: { duration: .2, ease: [.4, 0, 1, 1] } }}
          transition={reduced ? { duration: .08 } : {
            y: { type: "spring", stiffness: 340, damping: 30, mass: .65, delay: .06 },
            scale: { type: "spring", stiffness: 340, damping: 30, mass: .65, delay: .06 },
            opacity: { duration: .28, delay: .06 },
            filter: { duration: .36, delay: .04, ease: [.22, 1, .36, 1] },
          }}>
          <span className="status-label-text">{label}</span>
        </motion.span>
      </AnimatePresence>
    </span>
  </div>;
}
