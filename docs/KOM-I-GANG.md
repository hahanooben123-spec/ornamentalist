# Ornamentalist — fra Windows til din iPad

## Første start

1. Find `dist/Ornamentalist-iPad.zip` i projektmappen på Windows. Kopiér ZIP-filen til en filplacering, du allerede kan åbne fra din iPad, eksempelvis OneDrive eller iCloud Drive.
2. Åbn **Filer** på iPad og tryk på ZIP-filen for at pakke den ud.
3. Åbn **Ornamentalist.swiftpm** i **Swift Playground**, og tryk **Kør app**. Det er denne mappe/pakke, du skal åbne — ikke filen `Package.swift` alene.
4. Tryk **New drawing**, giv tegningen et navn, og vælg **Create drawing**. Tegn med din Apple Pencil. Standardindstillingen er otte symmetrikopier og en sort fineliner med konstant bredde.

Hvis du bruger GitHub i stedet for den lokale ZIP, ligger kildekoden i [dit repository](https://github.com/hahanooben123-spec/ornamentalist). Under **Actions → Apple validation → en bestået kørsel → Artifacts → Ornamentalist-iPad** kan du hente iPad-pakken. GitHub pakker selve ZIP-filen ind i en ekstra ZIP; pak begge ud, indtil du ser `Ornamentalist.swiftpm`.

## Det vigtigste i appen

I version 0.3.0 kan du bruge **Symmetry → Mirror** til spejling på begge sider af hjælpelinjerne og **Layers** til at oprette, vælge, skjule, låse, omdøbe, flytte og slette lag. [Se vejledningen til Mirror og lag](MIRROR-OG-LAG.md). Eksportér gamle tegninger som redigerbare projekter, før du erstatter din appkopi.

- **Farvecirklen øverst:** farvehjul, mætning, lyshed, HEX, palet og seneste farver. [Se farve- og lagvejledningen](FARVER-OG-OPACITY.md).
- **Viskelæder/pipette øverst:** fjern indhold fra det valgte lag eller vælg farven fra tegningen. [Se redigeringsvejledningen](REDIGERING-OG-LAG.md).
- **Layers:** miniaturebilleder, opacity fra 0–100 %, øje til/fra samt **Duplicate layer / Merge down** i lagmenuen.
- **Symmetry:** åbner et lille panel med hurtige valg og en præcis tæller fra 1 til 64. Antallet ændrer kun nye streger. **Show guides** slår hjælpelinjerne til eller fra.
- **Brushes:** 14 pensler til blæk, bløde skygger, prikker, stipple og tekstur. [Se penselvejledningen](PENSLER.md). Justér størrelse, styrke, afstand, tæthed, trykfølsomhed og stabilisering. Vælg 0% for direkte bevægelse eller en højere værdi for mere udglatning.
- **To fingre:** flyt, zoom og rotér lærredet. Pencil tegner; fingrene laver som standard ingen streger.
- **Undo / Redo:** fortryd eller gendan en hel streg med alle dens symmetrikopier.
- **Gallery:** ikonet øverst til venstre gemmer tegningen og går tilbage. Brug søgefeltet til at finde et værk og prikmenuen ved titlen til **Rename**.
- **Eksportikonet → PNG · White paper / Transparent:** et færdigt billede med hvid eller gennemsigtig baggrund.
- **Eksportikonet → Editable project:** en redigerbar `.ornamentalist.json`-fil, som du kan gemme i Filer. **Import** i galleriet åbner filen som et nyt projekt.
- **Fokusikonet øverst til højre:** skjuler værktøjerne. Tryk på det tilbageværende ikon for at vise dem igen.
- **Canvas:** tilpas tegningen til skærmen, slå fingertegning til, og vælg lyst eller mørkt udseende.

PNG er et billede. Brug den redigerbare projektfil, når du vil kunne arbejde videre, tage backup eller flytte en tegning til en ny appinstallation. Eksportér den redigerbare fil før en opdatering, der erstatter dit app-playground-projekt.

## Vores arbejdsgang fremover

Vi ændrer kildekoden på Windows og gemmer den på GitHub. GitHubs cloud-Mac bygger appen og kører automatiske tests. Derefter overfører vi en opdateret iPad-pakke til din iPad og tester med din Pencil. Koden på Windows/GitHub er hovedversionen.

På denne Windows-computer kan en ny iPad-pakke laves fra projektmappen med:

```powershell
python tools/package_ipad.py
```

Det pakker kildekoden. Selve Apple-kompileringen foregår på iPad eller cloud-Mac’en.

## Første Pencil-test — cirka fem minutter

1. Tegn langsomt og hurtigt med otte kopier. Alle kopier skal følge med, mens Pencil stadig rører skærmen.
2. Prøv 64 kopier. Zoom, flyt og rotér lærredet; tegn igen. Kopierne skal stadig passe omkring samme centrum.
3. Prøv Undo/Redo, gå til Gallery, og genåbn tegningen.
4. Eksportér både en PNG og en redigerbar projektfil. Importér projektfilen og kontrollér, at du kan tegne videre på kopien.
5. Vælg **Canvas → Drawing performance → Copy report**. Send rapporten sammen med din iPad-model og iPadOS-version, hvis du oplever hak eller forsinkelse.

Cloud-testene kontrollerer kode og grafik i simulatoren. Pencil-følelse, håndfladeafvisning og den konkrete Swift Playground-version skal stadig testes på din iPad.

## Når du får en opdateret pakke

Ændringer på Windows og GitHub opdaterer ikke automatisk det projekt, du allerede har åbent i Swift Playground. Hent pakken fra den nye buildkørsel, pak den ud i en ny mappe i Filer, og åbn den nye `Ornamentalist.swiftpm`. Behold den tidligere kopi, især hvis den indeholder tegninger. Åbn hele pakken frem for kun at udskifte `OrnamentalistApp.swift`.

Version 0.7.0 kan ses nederst i **Canvas** og i Drawing performance-rapporten. Konsollen skriver `Ornamentalist 0.7.0: app entry reached` ved opstart. Derefter følger markører for synligt studio og afsluttet galleriindlæsning, hvis konsollen er tilsluttet. En tom konsol beviser ikke, hvor nedbruddet sker. Se [gennemgangen af opstarten](CRASH-AUDIT.md) og [hastighedsvejledningen](HASTIGHED.md).

### Hvis en fil vises som “not in a target”

1. Tryk **Stop**, og gå tilbage til projektoversigten i Swift Playground.
2. I Filer: pak den nye pakke ud i en ny lokal mappe under **På min iPad**. Behold den tidligere projektkopi.
3. Åbn hele den nye **Ornamentalist.swiftpm**. Vælg **App → OrnamentalistApp** i editoren, og tryk ▶.

Version 0.7.0 har en eksplicit liste med alle 29 appfiler i buildmålet. Hvis fejlen fortsætter, er det stadig nødvendigt at undersøge den konkrete Swift Playground-/filudbydertilknytning. Sletning af appdata er ikke en del af dette forsøg.

### Hvis Package.swift viser dubletter eller manifestfejl

På den fotograferede iPad-kopi stod både den gamle og den nye appversion samt to executableTarget-blokke i samme manifest. Et senere billede viste sources-listen uden for target-kaldet. Begge strukturer er ugyldige; billederne fastslår ikke, hvordan dubletterne opstod. GitHub-versionen har ét produkt, ét target og alle 29 filstier inde i sources. Pakkekontrollen afviser nu netop disse fejltyper.

Stop projektet i Swift Playground, før dets filer opdateres. Undgå flere manuelle delrettelser af manifestet. Ved lokale ændringer i Working Copy skal den ene fil `Ornamentalist.swiftpm/Package.swift` gendannes til repositoryets version; en Pull alene er ikke bevis for, at lokale ændringer er væk. Den yderste `Package.swift` til modeltests skal ikke kopieres ind i apppakken. Hvis den åbne Playground er en separat importeret kopi, opdaterer Working Copy ikke den kopi.

Eksportér tegninger som redigerbare projekter fra den fungerende appkopi, før du flytter til en ny appkopi. Behold den gamle kopi og dens data. Fortsætter fejlen med en frisk, komplet pakke, skal den nye første fejl og manifestet fra netop den åbnede appkopi undersøges; en bestået simulatorbuild afgør ikke dette.

Viser en tidligere version fejlen **Ambiguous use of 'cos'** i `StudioPanels`, indeholder 0.2.2 en rettelse af taltyperne i symmetriens forhåndsvisning. Åbn den fulde, opdaterede `Ornamentalist.swiftpm` frem for diagnosepakken i `Diagnostics`. Du behøver ikke længere ændre startskærmen til `Text(...)` for denne fejl.
