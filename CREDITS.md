# Credits

Everything Sissy itself is made of is covered by [LICENSE](LICENSE).

No third-party code ships in Sissy. These are the projects it reads from,
and they are owed a credit whether or not a licence asks for one.

- [`ccusage`](https://github.com/ccusage/ccusage): the cost oracle Sissy
  measures itself against, and where its reading of the Claude Code and Codex
  JSONL schemas comes from.
- [LiteLLM](https://github.com/BerriAI/litellm): the model price table Sissy
  fetches at runtime, which is what `ccusage` prices from too.
