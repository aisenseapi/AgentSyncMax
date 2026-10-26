# Aider Mission-profil

Sist revidert mot AgentSync v4.0.5: 4. september 2026.

Status: Kommando- og lagringsprofilen er kontrollert mot Rust-motoren og
konfigurasjonen. Den installerte CLI-varianten ble tidligere verifisert med en
fullført AgentSync-mission mot Ollama på NVIDIA DGX Spark.

## Installert variant

- Aider-versjon: `0.86.2`
- Modell: `ollama_chat/qwen3-coder-next:q8_0`
- Ollama-endepunkt: `http://127.0.0.1:11435`
- Vert: NVIDIA DGX Spark
- Transport: lokal port gjennom SSH-tunnel
- API-nøkkel: ikke nødvendig for dette lokale endepunktet

AgentSync setter `OLLAMA_API_BASE` bare for Aider-prosessen. Den lagrer ingen API-nøkkel i Mission-profilen.

## Prompttransport

AgentSync oppretter en unik midlertidig UTF-8-fil per mission og starter Aider med:

```text
aider --message-file <midlertidig-promptfil>
```

`--message-file` utfører én melding og avslutter. Denne transporten fjerner Windows-grensen for lange og flerlinjede argumenter. En guard sletter promptfilen ved normal slutt, feil og tidlig retur.

## Viktige AgentSync-flagg

```text
--yes-always
--no-auto-commits
--no-dirty-commits
--no-attribute-author
--no-attribute-committer
--no-attribute-commit-message-author
--no-attribute-commit-message-committer
--no-attribute-co-authored-by
--no-gitignore
--no-check-update
--no-show-release-notes
--no-analytics
--no-pretty
--no-stream
--no-fancy-input
--no-notifications
--disable-playwright
```

`--no-git` brukes ikke. Aider beholder dermed Git-integrasjonen og repo-kartet.

## Git og endringskontroll

Aider bruker normalt Git aktivt og kan opprette commits. AgentSync beholder Git
for repo-kartet, men slår av automatiske commits, commits fra et allerede urent
arbeidstre og all Aider-attribusjon. Oppdragsteksten forbyr også commit, push,
rebase og andre endringer i Git-historikken.

AgentSync har sin egen todelte kontroll rundt kjøringen:

- Git-prosjekt: AgentSync leser status og diff uten å la agenten committe.
- Mappe uten Git: AgentSync lager checkpoint og sammenligner filtilstanden.

Dette gir Aider prosjektoversikt uten at den overtar AgentSync sin
endringskontroll eller skriver agentidentitet til Git.

## Prosjektkontekst

Repo-kartet gir den brede prosjektoversikten. AgentSync sender i tillegg opptil
seks prioriterte tekstfiler, maksimalt 96 KiB per fil og 300 KiB samlet.
Eksplisitt nevnte filer kommer først, deretter `AGENTS.md`, `AGENT_CONTEXT.md`,
README og sentrale prosjektmanifest som `Cargo.toml`, `package.json`,
`pyproject.toml`, `composer.json` og `go.mod`. Andre kildefiler legges ikke ved
bare fordi de er nylig endret. Runtime-state, dependency- og cachemapper,
hemmelighetsfiler, binærfiler, store filer og symlinker utelates.

Dette er grensen for de eksplisitt vedlagte filene, ikke for repo-kartet eller
modellens kontekstvindu.

## Historikk

AgentSync skiller mellom tre typer historikk:

- Tastetrykkhistorikken (`--input-history-file`) sendes til operativsystemets
  nullenhet fordi den er person- og maskinstøy.
- Chat-historikken lagres som
  `.agent-state/aider/<tidsstempel>.chat.md` i prosjektet.
- Modellutvekslingen lagres som
  `.agent-state/aider/<tidsstempel>.llm.md` i prosjektet.

Filene opprettes direkte av Aider gjennom stier AgentSync setter ved oppstart.
Det finnes derfor ingen separat native kilde- eller restore-adapter. Manifest,
Status, Recovery og Intelligence leser den prosjektlokale historikken som en
sjette provider. Dersom historikkmappen ikke kan opprettes, bruker kjøringen
nullenheten som sikker fallback; selve Mission-resultatet blir fortsatt lagret.

## Verifikasjon

- Lokal `aider --version`: 0.86.2
- Lokal `aider --help`: alle brukte flagg finnes
- Fullført Mission: modellen leste valgt prosjektkontekst, leverte slutttekst og rapporterte lokal modell
- Mission-historikk ved kontroll: én fullført og to eldre feilede Aider-kjøringer
- Rust-testen bekrefter promptfil, deaktiverte automatiske commits, aktiv Git-profil og prosjektlokale historikkfiler

## Failover

AgentSync endrer ikke Ollama-modell automatisk. Lokale modeller kan ha ulike edit-formater, kontekstvinduer og verktøyegenskaper. Modellbytte skal være et eksplisitt konfigurasjonsvalg.

## Kilder

- [Aider options reference](https://aider.chat/docs/config/options.html)
- [Aider med Ollama](https://aider.chat/docs/llms/ollama.html)
- [Aider Git integration](https://aider.chat/docs/git.html)
- Lokal `aider --help`, versjon 0.86.2
