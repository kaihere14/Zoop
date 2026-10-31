import type { NextConfig } from "next";

const config: NextConfig = {
  distDir: process.env.NODE_ENV === "production" ? ".next-build" : process.env.ZOOP_TEST_MODE === "1" ? ".next-test" : ".next",
  reactStrictMode: true,
  poweredByHeader: false,
  devIndicators: false,
};

export default config;
