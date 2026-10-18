# Isoleret starttest på iPad

Historisk diagnosepakke. Brug den fulde `Ornamentalist.swiftpm` til Mirror og lag i 0.3.0. Den tidligere byggefejl blev identificeret som en tvetydig `cos`-beregning og rettet i 0.2.2, som brugeren har bekræftet virker på iPad.

Apples nye standardprojekt kører på brugerens iPad. Ornamentalist fejler fortsat, også når `StudioView()` i startfilen erstattes med `Text(...)`. Den sidste ændring udelukker ikke kompileringsfejl i andre filer: alle appens kildefiler bygges stadig.

`Diagnostics/Ornamentalist-Starttest.swiftpm` indeholder derfor kun to filer: projektmanifestet og en enkelt app-kildefil. Manifestet bruger hovedprojektets opsætning med et særskilt bundle-id (`studio.mandala.prototype.starttest`) og en eksplicit filliste med kun diagnosepakkens ene kildefil. Startfilen er den samme som i hovedprojektet, med `StudioView()` erstattet af `Text("Pakketest virker")`. Der indlæses ingen af tegneappens øvrige kildefiler.

1. Hent den opdaterede repository-ZIP, og pak den ud i Filer i en ny mappe.
2. Åbn **Diagnostics → Ornamentalist-Starttest.swiftpm** i Swift Playground.
3. Tryk ▶. Resultatet skal være teksten **Pakketest virker**.

Hvis testen kører, understøtter iPad'en den minimale pakke og det eksisterende app-startpunkt; fejlen skal herefter isoleres i de øvrige filer eller deres build. Hvis den fejler, skal manifest/opstart sammenlignes med det fungerende Apple-standardprojekt. Testen skelner ikke alene mellem en manifestfejl, en compilerfejl og en runtimefejl.

Behold dit fungerende `Starttest`-standardprojekt til sammenligning. Diagnostikpakken erstatter ikke tegneappen eller dens data, og den retter ikke i sig selv hovedprojektets fejl.

Gendan eller regenerér diagnosepakken med `python tools/package_starttest.py`. Windows-kontrollen validerer indhold, Swift-syntaks og ZIP-integritet; den er ikke en Apple-kompilering. Den tidligere grønne app-testkørsel på GitHub kompilerede ikke denne diagnosepakke.
