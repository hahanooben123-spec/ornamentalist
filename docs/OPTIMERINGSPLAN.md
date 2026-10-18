# Optimeringsplan for Ornamentalist

Udgangspunkt: kildekoden til 0.9.8. Planen ændrer ikke appen eller eksisterende
tegninger. Målet er en stabil tegneoplevelse på ejerens iPad, med plads til både
enkle og detaljerede mandalaer. App Store-udgivelse er fortsat udskudt.

## Arbejdsform

- Én afgrænset ændring og én testpakke pr. iteration. Fortsæt fra eksisterende filer.
- Hver levering angiver version, ændring, tekniske kontrolresultater og højst tre
  konkrete testpunkter til ejeren. Fysisk Pencil-følelse bedømmes på iPad.
- Skeln mellem syntakskontrol, Swift-tests, native kompilering og fysisk test.
  En pakket ZIP er ikke dokumentation for, at appen kompilerer eller føles rigtig.
- Brug korte kontroller til små UI-ændringer. GPU-, lag-, lagrings- og eksportændringer
  kræver relevante native tests. Lange kørsler må ikke skjule et allerede kendt problem.
- Hvis en lille opgave overstiger ti minutter, giv konkret status og lad ejeren
  vælge, om den skal fortsætte. Undersøg hængende processer frem for at genstarte blindt.
- Bevar tegninger, lag, eksisterende stregers udseende og fortryd. Ingen automatisk
  permanent sammenlægning af lag eller reduktion af eksportkvalitet.

## 1. Fastlæg en pålidelig baseline

**Problem:** Flere versioner er blevet testet, og CPU/GPU-tider viser ikke den
samlede Pencil-til-skærm-forsinkelse. Den viste rapport fra 0.9.3 beviser ikke
effekten af ændringerne i 0.9.8. Senere native resultater skal verificeres.

**Arbejde:**

1. Bekræft den faktisk åbnede iPad-version og få den seneste kildekode kompileret.
   Registrér iPad-model, Pencil, skærmens opdateringsfrekvens og lærredsstørrelse.
2. Lav tre genbrugelige projekter: enkel fineliner, blandet arbejde med skygger og
   et detaljeret projekt med flere lag. Gem størrelsen og antallet af streger,
   inputpunkter og prikker, så næste version får præcis samme belastning.
3. Registrér CPU/GPU p50 og p95, frame-intervaller, gentegningsårsager, genopbyggede
   lag/områder, hukommelsesforbrug og højeste forbrug samt åbne-/gemme-/eksporttid.
   Hold kold åbning, varm tegning og zoom/genopbygning adskilt.
4. Test almindelig tegning og udvalgte tunge tilfælde med Mirror, lange skygger,
   fortryd og zoom. Mål både efter opstart og efter 10–15 minutters brug.

**Mål, ikke allerede opnåede resultater:** Stabil 60 Hz-tegning i de aftalte
hverdagsscenarier; 120 Hz undersøges på understøttet iPad, når 60 Hz er stabilt.
Frame-budgetterne er henholdsvis 16,7 og 8,3 ms. Mål faktiske frame-intervaller;
CPU/GPU-tider alene må ikke kaldes Pencil-latens. Hukommelsen skal stabilisere sig
ved gentagelse af samme forløb. Ingen tidlig detailfejl i de aftalte projekter.

**Levering:** En kort før-måling med projekter og reproduktionstrin. Den afgør
efterfølgende måltal for projektsåbning og eksport; der gives ikke gættede sekunder.

## 2. Opdatér kun ændrede områder på lærredet

**Nuværende grundlag:** Rendererens lag-cache og trinvis bekræftet streggeometri
skal genbruges. De skal ikke erstattes med en fuld genoptegning pr. penprøve.

**Arbejde i separate iterationer:**

1. Registrér, hvorfor lag-cache genopbygges, og fjern ugyldiggørelser, der ikke
   skyldes en faktisk ændring af billede, visning eller lag.
2. Indfør cachede billedfelter for færdige streger, først for ét lag med almindelig
   tegning, derefter for skygger, viskelæder og Mirror. Feltstørrelse vælges ved måling.
3. Beregn berørte felter fra hele penselaftrykket og alle symmetrikopier. Medtag
   bløde kanter, tilt og tilstrækkeligt overlap ved feltgrænser, så der ikke kommer sømme.
4. Hold den aktuelle streg og dens korte forudsigelse adskilt fra færdige felter.
   Forudsigelser bliver aldrig gemt eller permanent malet ind i cachen.
5. Fortryd, lagflytning og billedtransformation skal ugyldiggøre de rigtige felter.
   Ved transformation medregnes både det tidligere og nye område.

**Godkendelseskriterium:** Varme frames genafspiller ikke gammel tegning uden
grund. Felter giver samme farve, opacity, viskelæder og Mirror som referencevejen,
inklusive overlap og feltgrænser. Frame-tider forbedres på iPad med samme projekt.

## 3. Gør GPU-arbejdshukommelsen uafhængig af hele projektets størrelse

**Problem:** Alle færdige stregers GPU-buffere bliver i dag bevaret. Et budget
for hele tegningens udvidede geometri kan derfor stoppe tegningen, selv om meget
af geometrien allerede findes i cachede lagbilleder.

**Arbejde:**

1. Adskil dokumentets redigerbare originaldata fra rendererens midlertidige
   geometribudget. Dokumentvalidering må ikke kræve, at hele projektet kan være
   udvidet på GPU'en samtidigt. Fil-, data- og sikkerhedsgrænser bevares separat.
2. Behold nødvendige buffere for aktuel streg og berørte felter. Frigiv ældre
   buffere efter et begrænset cachebudget; genskab dem fra originaldata ved behov.
3. Genopbyg efter zoom eller fortryd i afgrænsede portioner med mulighed for
   annullering. Vis aldrig en ufærdig cache som et færdigt lag.
4. Under hukommelsespres frigives genopbyggelige data først. Undgå en permanent
   overgang til dyr fuld genoptegning resten af sessionen, som cacheBudget=0 kan give nu.
5. Begræns antallet af samtidige upload-/genopbygningsjob og deres CPU-mellemdata.

**Godkendelseskriterium:** Et større dokument kan fortsat tegnes i, selv om dets
samlede geometri overstiger det midlertidige GPU-budget. Arbejdshukommelsen er
begrænset, og fortryd/genåbning genskaber identisk indhold. Ingen destruktiv rasterisering.

## 4. Optimér penfølelse og pensler med et fast testforløb

**Arbejde:**

- Sammenlign fra, 25, 50, 75 og 100 % stabilisering ved langsomme buer, små
  detaljer og hurtige streger. Høj styrke skal give en tydelig, forudsigelig effekt.
  Vurder både udglatning, efterslæb, kurveradius og slutpunkt.
- Kalibrér trykkurve og følsomhed til let hånd. Kontrollér begyndelse, løft og
  stregbredde ved lavt tryk. Undgå flere udokumenterede filterændringer i samme test.
- Brug faste toneprøver til skygger: samme pensel, størrelse, strøglængde og
  opacity. Test 5/10/20 % og flere passager, samt med og uden Mirror.
- Kontrollér falloff ved både langsom og hurtig tegning og ved forskellig opdeling
  i penprøver. Kantblødhed og udtoning skal matche Metal, forhåndsvisning og PNG.
- Gentag de relevante prøver med viskelæderet. Test at penselindstillinger huskes
  separat, og at hover kan slås fra uden at påvirke selve stregen.

**Godkendelseskriterium:** Ejeren kan mærke forskellen mellem indstillingerne og
opnå de ønskede rene buer og gradvise skygger. Automatisk replay supplerer denne
test; det erstatter ikke den fysiske vurdering.

## 5. Reducér lagring, autosave og fortryds belastning

**Arbejde:**

1. Mål hvor meget tid og hukommelse fulde JSON-snapshots og checkpoints bruger.
2. Indfør tabsfri komprimering af stregdata og en versioneret læsevej for ældre
   filer. Afprøv kompakte binære blokke, før formatet fastlægges. Prikkernes seed,
   rækkefølge, tryk, tilt og stregresultat skal bevares.
3. Gem nye ændringer i en kompakt journal og saml den til et fuldt snapshot i
   baggrunden. Bevar revisioner, atomisk gemning, backup og gendannelse.
4. Lad kun nødvendige ændringer blive gemt igen. Checkpoints under tegning skal
   fortsat indeholde bekræftet aktivt input, uden at en gammel journal genopliver slettet arbejde.
5. Mål også hukommelsen i fortrydshistorikken. Komprimér eller flyt ældre historik
   til lokal disk ved behov; afkort den ikke ubemærket.

**Godkendelseskriterium:** Gemning skaber ikke mærkbare pauser under tegning.
Genåbning, fortryd, app-afbrydelse og gendannelse bevarer tegningen. Komprimering
har dokumenteret effekt på filstørrelse og CPU-hukommelse, ikke kun på GPU-buffere.

## 6. Gør resten af arbejdsgangen hurtig og sammenhængende

- **Gallery:** Små forhåndsvisninger indlæses først. Reparation/generering arbejder
  i baggrunden og må ikke blokere tegning. Sortering følger senest ændrede projekt;
  sletning og genåbning bevarer korrekt tilstand.
- **Layers:** Genbrug miniaturebilleder. Generér kun nye for ændrede lag. Test
  skjul, lås, opacity, rækkefølge og fortryd uden fuld genopbygning af alle lag.
- **Indstillinger:** Klar tænd/sluk, præcise labels og løbende forudsigelige skydere.
  Gem præferencer automatisk. Undersøg unødige SwiftUI-opdateringer ved måling.
- **Billeder og transformation:** Åbning, flytning, skalering og annullering må
  ikke blokere input eller skabe unødige billedkopier. Fortryd skal genskabe originalen.
- **Eksport:** Brug originaldata og fuld aftalt opløsning, uafhængigt af skærmcachen.
  Hold den væk fra peninput og vis fremdrift ved større arbejde.
- **Fejl:** Bevar bekræftet arbejde og vis en præcis årsag. En genskabelig cache-
  fejl må ikke i sig selv tvinge brugeren til at opgive projektet.

**Godkendelseskriterium:** Et sammenhængende forløb fra Gallery til tegning,
viskelæder, lag, fortryd, gemning, genåbning og eksport fungerer med de samme tre
projekter. Testpakken har én entydig version og kendt buildstatus.

## Rækkefølge for det næste arbejde

1. Baseline og verifikation af den aktuelle appversion.
2. Ét lag med lokal opdatering og test af cache-ugyldiggørelse.
3. Skygger, viskelæder og Mirror på de cachede billedfelter.
4. Frigivelse/genopbygning af GPU-geometri og adskilt dokumentbudget.
5. Penkalibrering, komprimeret lagring og resten af arbejdsgangen i små leveringer.

Markering med tegnemaske og transformation af tegnede elementer bygger videre
på dette fundament bagefter. Billedlag og deres eksisterende transformation
skal fortsat fungere under alle optimeringer.
