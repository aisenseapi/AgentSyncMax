# Cline Mission-profil

Sist verifisert: 30. august 2026.

Status: Verifisert med native CLI, offisiell kommandoreferanse og reell smoketest mot lokal Ollama-provider.

## Installert variant

- Versjon: `3.0.60`
- Plattform: native Windows x64 CLI
- Testmodell rapportert av Cline: `nemotron-3-super:latest`
- Testprovider rapportert av Cline: `ollama`

AgentSync foretrekker native `cline.exe`. En `.cmd`-starter er bare fallback og blir avvist når prompten er større enn 6000 UTF-16-tegn, fordi Windows-kommandoskallet har en lav kommandolinjegrense.

## AgentSync-kommando

```text
cline
  --json
  --auto-approve true
  --retries 3
  --cwd <prosjektmappe>
  <prompt>
```

Cline mottar prompten som sitt dokumenterte posisjonelle promptargument. Native exe gjør at argumentet ikke går gjennom `cmd.exe`.

## Hvorfor retries er med

Cline dokumenterer `--retries` som maksimalt antall påfølgende modellfeil før kjøringen stoppes. En tidligere AgentSync-mission kom helt inn i agentløkken, men den lokale modellen leverte ugyldig XML-verktøysyntaks:

```text
XML syntax error: element <function> closed by </parameter>
```

Det var ikke en CLI- eller prosessstartfeil. AgentSync bruker derfor tre interne Cline-forsøk. Dette lar samme modell korrigere en formatfeil uten at AgentSync skjult bytter agent.

## Tillatelser

`--auto-approve true` er nødvendig for kodearbeid uten Cline sitt interaktive grensesnitt. AgentSync viser diff eller checkpoint etterpå og forbyr commit, push og endring av `.agent-state` i Mission-prompten.

## Utdata

`--json` gir én JSON-hendelse per linje. Cline kan sende mange små `content_start`-fragmenter, inkludert tokenvise tekstfragmenter. AgentSync må derfor behandle strømmen inkrementelt og begrense visningsloggen uten å miste terminalhendelsen `run_result`.

## Verifikasjon

Smoketest 30. august 2026:

- Profil: JSON, auto-approve, retries 3, timeout og valgt tom mappe
- Exit code: `0`
- Iterasjoner: `1`
- Verktøykall: `0`
- Kostnad rapportert av Cline: `0`
- Opprettede prosjektfiler: `0`
- Terminalhendelse: `run_result` med `finishReason: completed`

Modellen la inn mellomrom i den forespurte kontrollteksten. Det er en modellpresisjonsobservasjon, ikke en transport- eller CLI-feil.

## Failover

De tre retry-forsøkene er profilens eneste automatiske failover. AgentSync endrer ikke Cline-provider eller modell automatisk. Det kunne ha flyttet oppdraget fra lokal Ollama til en betalt tjeneste.

## Kilder

- [Cline CLI reference i offisiell kildekode](https://github.com/cline/cline/blob/main/docs/cli/cli-reference.mdx)
- Lokal `cline --help`, versjon 3.0.60
- Lokal AgentSync-smoketest 30. august 2026
