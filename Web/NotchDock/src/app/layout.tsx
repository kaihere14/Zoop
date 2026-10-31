import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Zoop — Your Mac has room for two.",
  description: "A little companion for your big ideas. Try Zoop’s interactive macOS notch experience.",
  icons: { icon: "/icon.svg" },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
