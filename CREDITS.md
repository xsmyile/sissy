# Credits

Sissy's own source code is covered by [LICENSE](LICENSE); its name and its
artwork are not, and [NOTICE](NOTICE) says what that means.

One third-party project ships inside Sissy.app:

- [Sparkle](https://github.com/sparkle-project/Sparkle): checks for, downloads
  and installs Sissy's own updates. MIT, with the external licences it carries;
  [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) reproduces them, and the app
  bundles that file because the BSD terms among them ask for it.

The rest are projects Sissy reads from, and one it takes two pictures from.
All are owed a credit whether or not a licence asks for one.

- [`ccusage`](https://github.com/ccusage/ccusage): the cost oracle Sissy
  measures itself against, and where its reading of the Claude Code and Codex
  JSONL schemas comes from.
- [LiteLLM](https://github.com/BerriAI/litellm): the model price table Sissy
  fetches at runtime, which is what `ccusage` prices from too.
- [Simple Icons](https://github.com/simple-icons/simple-icons): where the
  GitHub and GitLab artwork Sissy draws comes from, released under CC0.

## Trademarks

"Sissy", the Sissy icon and the mascot artwork are the copyright holder's
own marks. They travel with neither the MIT licence nor a fork: [NOTICE](NOTICE)
is where that is set out.

Sissy draws the Claude and OpenAI marks to identify which CLI a row is about,
and the GitHub and GitLab marks to identify where a repository is pushed. They
are the trademarks of Anthropic, OpenAI, GitHub and GitLab respectively, used
nominatively; none of those companies is affiliated with Sissy, and none
endorses it. The GitHub and GitLab files are Simple Icons' (CC0); the Claude
and OpenAI ones are each vendor's own published mark. CC0 covers a drawing and
never a trademark.
