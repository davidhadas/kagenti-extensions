/// <reference types="vite/client" />

// Allow CSS side-effect imports
declare module '*.css' {
  const content: Record<string, string>;
  export default content;
}
