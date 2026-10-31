import type { Config } from "tailwindcss";

export default {
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: { lime: { 400: "#b6f542" }, obsidian: "#0f1218" },
      fontFamily: {
        sans: ["Arial", "Helvetica Neue", "sans-serif"],
        mono: ["SFMono-Regular", "Consolas", "monospace"],
      },
      backgroundImage: {
        "liquid-glass": "linear-gradient(180deg, #000 0%, rgba(5,5,7,.98) 10%, rgba(12,14,18,.91) 48%, rgba(15,18,24,.72) 100%)",
        "glass-border": "linear-gradient(180deg, rgba(255,255,255,.22) 0%, rgba(255,255,255,.03) 60%, rgba(182,245,66,.12) 100%)",
      },
      backdropBlur: { glass: "40px" },
      backdropSaturate: { glass: "2.1" },
      boxShadow: {
        notch: "0 24px 100px -30px rgba(0,0,0,.8), 0 55px 90px -65px rgba(182,245,66,.45)",
      },
    },
  },
  plugins: [],
} satisfies Config;
