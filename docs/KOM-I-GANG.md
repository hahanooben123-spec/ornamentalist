# Ornamentalist — fra Windows til din iPad

## Første start

1. Find `dist/Ornamentalist-iPad.zip` i projektmappen på Windows. Kopiér ZIP-filen til en filplacering, du allerede kan åbne fra din iPad, eksempelvis OneDrive eller iCloud Drive.
2. Åbn **Filer** på iPad og tryk på ZIP-filen for at pakke den ud.
3. Åbn **Ornamentalist.swiftpm** i **Swift Playground**, og tryk **Kør app**. Det er denne mappe/pakke, du skal åbne — ikke filen `Package.swift` alene.
4. Tryk **New canvas**, og tegn med din Apple Pencil. Standardindstillingen er otte symmetrikopier og en sort fineliner med konstant bredde.

Hvis du bruger GitHub i stedet for den lokale ZIP, ligger kildekoden i [dit repository](https://github.com/hahanooben123-spec/ornamentalist). Under **Actions → Apple validation → en bestået kørsel → Artifacts → Ornamentalist-iPad** kan du hente iPad-pakken. GitHub pakker selve ZIP-filen ind i en ekstra ZIP; pak begge ud, indtil du ser `Ornamentalist.swiftpm`.

## Det vigtigste i appen

- **Radial ×8 / − / +:** ændrer antallet af kopier. Menuen med symmetriikonet har hurtige valg som 4, 8, 16 og 64. Antallet ændrer kun nye streger.
- **Width:** stregbredde. Under **Fineliner** kan du slå trykfølsomhed til og vælge stabilisering. Vælg 0% for direkte bevægelse eller en højere værdi for mere udglatning.
- **To fingre:** flyt, zoom og rotér lærredet. Pencil tegner; fingrene laver som standard ingen streger.
- **Undo / Redo:** fortryd eller gendan en hel streg med alle dens symmetrikopier.
- **Gallery:** gemmer tegningen og går tilbage. Hold fingeren på en tegning i galleriet, og vælg **Rename** for at give den et navn.
- **Save and export → Export PNG:** et færdigt billede med hvid eller gennemsigtig baggrund.
- **Save and export → Export editable project:** en redigerbar `.ornamentalist.json`-fil, som du kan gemme i Filer. **Import project** i galleriet åbner filen som et nyt projekt.

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
5. Vælg **Canvas → Performance report → Copy report**. Send rapporten sammen med din iPad-model og iPadOS-version, hvis du oplever hak eller forsinkelse.

Cloud-testene kontrollerer kode og grafik i simulatoren. Pencil-følelse, håndfladeafvisning og den konkrete Swift Playground-version skal stadig testes på din iPad.
