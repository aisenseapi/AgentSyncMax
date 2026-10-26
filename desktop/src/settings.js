// Switches for what AgentSync Max does and shows.
//
// The rule that makes the hierarchy behave: turning a master off never writes
// to its children. `enabled()` walks up the chain instead, so a child that is
// hidden by its master keeps its own remembered value and comes back exactly
// as it was when the master returns. Nothing has to be saved and restored.
(() => {

const KEY = "agentsync.v4.settings";
// Kept apart from the switch values on purpose. Wiping one must never wipe the
// other: a reset to defaults is a statement about what should happen next, not
// a claim that nothing was ever used.
const USE_KEY = "agentsync.v4.settings.use";

// Each switch names what it does in the user's terms, not the code's. `under`
// is the master it depends on; a switch is only in effect when every master
// above it is on as well.
const SWITCHES = [
  // --- Validation ---------------------------------------------------------
  { id: "validation", group: "Validering", label: "Valideringsagent",
    help: "Hovedbryteren. Av her stopper alle kontroller, og panelet lukkes.", default: true },
  { id: "validation.auto", under: "validation", group: "Validering", label: "Start av seg selv",
    help: "Start nye kontroller etter skriveoppdrag som endret filer. Av tømmer ventende kontroller; pågående arbeid stoppes med hovedbryteren V.", default: true },
  { id: "validation.rotate", under: "validation.auto", group: "Validering", label: "Roter mellom agentene",
    help: "Velg den agenten som validerte lengst siden. Av: bruk den du har valgt i panelet.", default: true },
  { id: "validation.estimate", under: "validation.auto", group: "Validering", label: "Vis hva den vil koste",
    help: "«3 filer, anslagsvis 4 minutter» mens den venter.", default: true },
  { id: "validation.floor", under: "validation.auto", group: "Validering", label: "Hopp over de minste endringene",
    help: "Én endret fil er sjelden verdt halvannet minutt. Av: kontroller uansett størrelse.", default: true },
  { id: "validation.showFindings", under: "validation", group: "Validering", label: "Vis funnene av seg selv",
    help: "Legg funnene fram når en kontroll er ferdig, uten at du klikker raden.", default: true },
  { id: "validation.blind", under: "validation.auto", group: "Validering", label: "Kjør i blind kopi",
    help: "På: kontrollen ser en kopi uten .git og uten de andre agentenes historikk, så uavhengigheten er en egenskap ved mappen. Av: den kjører i prosjektet selv, og uavhengigheten hviler bare på teksten i oppdraget. Registeret skiller de to, så du kan se om kopien er verdt det. Merk at en delt kontroll ikke kan kjøre mens en annen agent arbeider i samme prosjekt; den blir stående til prosjektet er ledig.", default: true },
  { id: "validation.progress", under: "validation", group: "Validering", label: "Vis hvor lenge den har kjørt",
    help: "«arbeider · 3 min» på raden, og et varsel når den går forbi anslaget. Sju minutter uten tegn til liv ser ut som en hengt prosess.", default: true },

  // --- Between the agents -------------------------------------------------
  { id: "collab", group: "Samarbeid", label: "Del mellom agentene",
    help: "Hovedbryteren for alt én agent får vite om de andre.", default: true },
  { id: "collab.posts", under: "collab", group: "Samarbeid", label: "La agenten se de andres oppdragsposter",
    help: "De fem siste ukens skriveoppdrag fra andre agenter i samme prosjekt: hva som ble bedt om og hvilke filer som ble endret. Ikke historikken og ikke resonnementet. Blinde kontroller får dette aldri.", default: true },
  { id: "collab.handovers", under: "collab", group: "Samarbeid", label: "Vis registrerte overganger mellom oppdrag",
    help: "Filendringer registrert i oppdrag fra ulike agenter, i tidsrekkefølge. Dette beviser ikke forfatterskap eller at noen overskrev en annens arbeid.", default: true },

  // --- Getting from a finding to an action --------------------------------
  { id: "flow", group: "Flyt", label: "Snarveier og måling av egen tid",
    help: "Hovedbryteren for det som forkorter veien fra lest funn til handling.", default: true },
  { id: "flow.shortcut", under: "flow", group: "Flyt", label: "Ctrl+Enter sender øverste funn",
    help: "Når funnpanelet er synlig og har fokus utenfor et skrive- eller valgfelt. Snarveien bruker de samme sperrene som send-knappen.", default: true },
  { id: "flow.deliberation", under: "flow", group: "Flyt", label: "Mål tiden fra funnet vises til du handler",
    help: "Forløpt tid fra funnlisten først vises til du sender en oppfølging, ikke dokumentert aktiv lesetid. Oppstartstid og pauser over ett døgn utelates. Lagres på oppfølgingskoblingen.", default: true },

  // --- What a finding says ------------------------------------------------
  { id: "findings", group: "Funn", label: "Funnkortene",
    help: "Hovedbryteren for alt som står på et funn utover tittel og tekst.", default: true },
  { id: "findings.limit", under: "findings", group: "Funn", label: "Hva som ikke ble sjekket",
    help: "Validatorens egne ord om hva den ikke fikk verifisert. Kvalifiserer også et rent svar.", default: true },
  { id: "findings.confidence", under: "findings", group: "Funn", label: "Hvor sikker den er",
    help: "Vises bare når den er mindre enn sikker.", default: true },
  { id: "findings.test", under: "findings", group: "Funn", label: "Testen som ville fanget det",
    help: "Når rapporten gir grunnlag for å navngi en.", default: true },
  { id: "findings.echo", under: "findings", group: "Funn", label: "Merk gjentakelse av skriveren",
    help: "Vis tekstlig sammenfall med skriveagentens konklusjon. Likhet alene sier ikke om kontrollen var uavhengig eller nyttig.", default: true },
  { id: "findings.ownWork", under: "findings", group: "Funn", label: "Merk agentens eget arbeid",
    help: "Marker tidligere filendringer registrert i oppdrag fra samme agent. Et forbehold om uavhengighet, ikke bevist forfatterskap.", default: true },
  { id: "findings.history", under: "findings", group: "Funn", label: "Hva som har skjedd før",
    help: "«meldt to ganger før», «filen er meldt tre ganger før», «sendt til Claude Code».", default: true },
  { id: "findings.group", under: "findings", group: "Funn", label: "Samle funn per fil",
    help: "Fire funn i én fil er ett problem. Filen med flest kommer først.", default: true },
  { id: "findings.peek", under: "findings", group: "Funn", label: "Vis teksten ved hover",
    help: "Hele kritikken i appens egen ramme. Av: bare knappen «Vis teksten».", default: true },

  // --- The record ---------------------------------------------------------
  { id: "record", group: "Register", label: "Vis det registeret vet",
    help: "Hovedbryteren for tall og opphav hentet fra oppdragspostene.", default: true },
  { id: "record.agent", under: "record", group: "Register", label: "Agentens historikk",
    help: "«90 % fullført av 20 oppdrag · sist i dag» ved siden av agentvalget.", default: true },
  { id: "record.failures", under: "record.agent", group: "Register", label: "Varsle om de siste kjøringene feilet",
    help: "En prosent over hele historikken skjuler en agent som gikk i stykker i går. Stille svikt er den dyreste sorten.", default: true },
  { id: "record.authors", under: "record", group: "Register", label: "Registrerte filendringer",
    help: "Filendringer registrert i oppdrag. Dette beviser ikke hvem som skrev ved samtidig arbeid.", default: true },
  { id: "record.sinceLast", under: "record", group: "Register", label: "Hva som er nytt siden sist",
    help: "Antall kjøringer i prosjektet siden du sist så på det. Nullstilles når du åpner det.", default: true },
  { id: "record.machine", under: "record", group: "Register", label: "Merk kjøringer fra andre maskiner",
    help: "Poster følger synken. En kjørt et annet sted leses som lokal uten dette.", default: true },
  { id: "record.command", under: "record", group: "Register", label: "Kommandolinjer i aktivitetsloggen",
    help: "Vis linjer merket «Kommando:», både oppstartsflagg og verktøykommandoer. Av skjuler bare visningen her; linjene beholdes i oppdragsjournalen.", default: true },
];

const BY_ID = new Map(SWITCHES.map((item) => [item.id, item]));

function readUse() {
  try {
    const stored = JSON.parse(window.localStorage.getItem(USE_KEY) || "{}");
    return stored && typeof stored === "object" && !Array.isArray(stored) ? stored : {};
  } catch {
    return {};
  }
}

function readStored() {
  try {
    const stored = JSON.parse(window.localStorage.getItem(KEY) || "{}");
    return stored && typeof stored === "object" && !Array.isArray(stored) ? stored : {};
  } catch {
    return {};
  }
}

let stored = readStored();
let uses = readUse();

// A feature is used when it actually did something for someone, not when the
// code that could do it ran. Called from the places where the effect is
// visible, so "nobody has touched this in three weeks" means what it says.
function used(id) {
  if (!BY_ID.has(id) || !enabled(id)) return;
  const now = Date.now();
  let changed = false;
  // A child doing visible work is also evidence for its active masters.
  // These are observed active minute-buckets, not user-click/run counts.
  for (let item = BY_ID.get(id); item; item = item.under ? BY_ID.get(item.under) : null) {
    const before = lastUsed(item.id);
    if (before && now >= before.at && now - before.at < 60_000) continue;
    uses[item.id] = { at: now, count: (before?.count || 0) + 1 };
    changed = true;
  }
  if (!changed) return;
  try {
    window.localStorage.setItem(USE_KEY, JSON.stringify(uses));
  } catch {
    // A use that cannot be recorded is still a use.
  }
}

function lastUsed(id) {
  const value = uses[id];
  return value && Number.isFinite(value.at) && value.at > 0
    && Number.isSafeInteger(value.count) && value.count > 0 ? value : null;
}

function write() {
  try {
    window.localStorage.setItem(KEY, JSON.stringify(stored));
  } catch {
    // A switch that cannot be saved still works for this session.
  }
}

// The switch's own value, ignoring its masters. This is what the panel shows
// and what survives a master being turned off and on again.
function own(id) {
  const item = BY_ID.get(id);
  if (!item) return false;
  return typeof stored[id] === "boolean" ? stored[id] : item.default;
}

// In effect: its own value, and every master above it.
function enabled(id) {
  let item = BY_ID.get(id);
  if (!item) return true;
  while (item) {
    if (!own(item.id)) return false;
    item = item.under ? BY_ID.get(item.under) : null;
  }
  return true;
}

// Why a switch is greyed out, for the panel to say.
function blockedBy(id) {
  let item = BY_ID.get(id);
  if (!item) return null;
  item = item.under ? BY_ID.get(item.under) : null;
  while (item) {
    if (!own(item.id)) return item;
    item = item.under ? BY_ID.get(item.under) : null;
  }
  return null;
}

function set(id, value, { notify = true } = {}) {
  if (!BY_ID.has(id)) return;
  stored[id] = Boolean(value);
  write();
  if (notify) window.dispatchEvent(new CustomEvent("agentsync:settings", { detail: { id, value: Boolean(value) } }));
}

function reset() {
  // Retired keys remain intact, but no longer pretend to control the engine.
  for (const item of SWITCHES) delete stored[item.id];
  write();
  window.dispatchEvent(new CustomEvent("agentsync:settings", { detail: { id: null, value: null } }));
}

function groups() {
  const order = [];
  const byGroup = new Map();
  for (const item of SWITCHES) {
    if (!byGroup.has(item.group)) {
      byGroup.set(item.group, []);
      order.push(item.group);
    }
    byGroup.get(item.group).push(item);
  }
  return order.map((name) => ({ name, items: byGroup.get(name) }));
}

// How many switches are off, so the rail can say the setup is not the default.
function changedCount() {
  return SWITCHES.filter((item) => item.id !== "validation" && own(item.id) !== item.default).length;
}

window.AgentSyncSettings = { enabled, own, set, reset, groups, blockedBy, changedCount, used, lastUsed, KEY, USE_KEY };

})();
