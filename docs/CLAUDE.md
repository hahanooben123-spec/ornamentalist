# Claude som ekstra kodehjælper

Claude Code bruges fra Windows til en uafhængig gennemgang af projektet. Den er ikke en del af iPad-appen. `CLAUDE.md` i projektets rod forklarer arkitekturen, de to forskellige Package.swift-filer og de observerede iPad-fejl.

## Login og gennemgang

Claude Code skal være installeret, og du skal selv logge ind med en konto, der har Claude Code-adgang. Installation alene betyder ikke, at en kodegennemgang er kørt. Kontoen og login gemmes lokalt af Claude Code; nøgler og engangskoder skal ikke lægges i projektet eller i chatten.

```powershell
claude auth login --claudeai
```

Åbn en terminal i projektmappen. Kontrollér opsætningen:

```powershell
.\tools\claude-review.ps1 -CheckOnly
```

Kør den forberedte gennemgang af iPad-manifest og levering:

```powershell
.\tools\claude-review.ps1
```

Scriptet bruger kun Read, Glob og Grep, afgrænser filadgang med restricted mode og indlæser ingen MCP-servere. Det giver ikke Claude skriveværktøjer eller en shell. Resultatet vises i terminalen; Claude committer eller pusher ikke ændringer. En kodegennemgang bruger din Claude-adgang og dens forbrugsgrænser. En eventuel rettelse vurderes, testes og pushes bagefter.

Et nyt terminalvindue kan være nødvendigt efter installation, før `claude` findes på PATH. Scriptet kan også finde standardinstallationen under brugerens `.local\bin`.

Officielle kilder: [installation og adgang](https://code.claude.com/docs/en/setup), [login](https://code.claude.com/docs/en/authentication), [CLI-flags](https://code.claude.com/docs/en/cli-reference).
