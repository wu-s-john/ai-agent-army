---
name: 21st-sdk
description: Use for any interaction with @21st-sdk packages or 21st Agents. Use when a task mentions @21st-sdk, 21st Agents, or 21st SDK for setup, implementation, troubleshooting, or general usage.
---

# 21st SDK / 21st Agents

1. For any @21st-sdk or 21st Agents task, fetch `https://21st.dev/agents/llms.txt` first.
2. Treat `llms.txt` as the primary entry point to the latest 21st SDK documentation.
3. IMPORTANT: To get Markdown content from docs URLs, ALWAYS add `md` in the docs path. Convert `/agents/docs/X` to `/agents/docs/md/X`.
4. Follow links from `llms.txt` for setup and implementation details instead of relying on memory.
5. You can optionally fetch `https://21st.dev/agents/llms-full.txt` for complete docs, but read only needed sections to avoid context overflow.
