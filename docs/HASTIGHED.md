# Hurtigere tegning — version 0.7.0

Versionen optimerer tegning og viskning. Dokumentformatet er fortsat 6; gemte strøg, prikmønstre, trykkurve og stabilisering ændres ikke. Nederst i **Canvas** skal der stå **Ornamentalist 0.7.0**, så den kørende kopi kan kontrolleres uden konsollen.

## Rendering

GPU-arbejdsteksturer genbruges ved uændret viewport-størrelse. På Apple-GPU'er bruger den midlertidige MSAA-arbejdstekstur tile memory (memoryless storage). MTKView opretter ikke længere en ekstra, ubrugt MSAA-skærmtekstur; artwork bruger fortsat fire samples, hvor GPU'en understøtter det.

Lagene under og over det aktive lag gemmes i to sammensatte, transparente billeder. Det aktive lags færdige indhold gemmes med sine enkelte MSAA-samples. Under en ny streg kopieres disse samples til arbejdsfladen, hvorefter kun den igangværende streg og dens forudsigelse tegnes. Det bevarer viskelæderets lagisolering og de bløde kanter. Forudsigelser kommer ikke ind i gemte caches eller projektdata.

Bekræftede nye dele af det igangværende strøg opsamles også inkrementelt i MSAA-cachen. Lange, ubrudte streger bliver derfor ikke dyrere at gentegne for hvert nyt punkt. Kun den nye del og den midlertidige forudsigelse behandles. Annullering gendanner basen fra dokumentet; afslutning tilføjer den manglende slutgeometri uden at male de gamle dele igen.

Et nyt færdigt strøg føjes inkrementelt til den aktive cache, når de gamle strøg fortsat er et præfiks. Undo, sletning, lagvalg, ombytning, rasterændringer, viewport og størrelse invaliderer berørte caches. Aktiv lag-opacity påføres ved sammensætning. Modelrevisionen styrer opdatering af lagindhold/cache-nøgler, så hele dokumentet ikke scannes hver frame.

Midlertidige vertexbuffere genbruges, når det levende indhold/forudsigelsen er uændret. Punktbudgettet opsamles under input, så strøget ikke skal gennemregnes igen, når Pencil løftes. Lagminiaturer har en separat cache med højst 32 resultater, som invalideres af indhold frem for skjul/vis og opacity.

## Hukommelse og kvalitet

Vedvarende viewport-caches har et samlet budget på 160 MiB. Arbejdsteksturer, kildegeometri, dokument-/historikdata og driverressourcer ligger ud over dette budget. Større renderflader, hukommelsesadvarsel eller mislykket cacheallokering bruger en ukachet reservevej med genbrugte arbejdsteksturer. Antialiasing og projektdata reduceres ikke automatisk.

Gamle viewport-caches frigives før en ny størrelse allokeres. Allerede indsendte GPU-kommandoer beholder ressourcer, de stadig bruger. Den synlige renderingsvej har højst én frame i gang; den venter ikke på en GPU-semafor på touch-tråden.

Sammenlægning af uændrede transparente lag til et fælles 8-bit cachebillede kan give små afrundingsforskelle i skærmvisningen. Native tests sammenligner cached/reference-rendering og de eksisterende PNG-pixels. PNG-eksport og gemte kildegeometrier bruger fortsat dokumentmodellen.

## Måling på iPad

1. Kontrollér **0.7.0** nederst i Canvas-panelet.
2. Tegn og visk i tegningen, der før hakkede. Prøv også blød skygge/stipple og Mirror ved normalt zoomniveau.
3. Vælg **Canvas → Drawing performance → Copy report**.
4. Gentag efter zoom/rotation. Arbejdsteksturernes allokeringstæller bør stabilisere sig ved uændret skærmstørrelse. Antallet af genafspillede færdige strøg bør ikke stige under et nyt strøg med varm cache, medmindre hukommelses-reservevejen er aktiv.

Rapporten viser median/p95 for CPU-indsendelse og GPU-arbejde, udskudte frames, cachebytes, teksturallokeringer, genopbygninger og inkrementelle commits. Det er ikke Pencil-til-skærm-forsinkelse eller samlet app-RAM. Simulatorbenchmarks inkluderer GPU-ventetid og pixel-readback; de dokumenterer ikke fysisk iPad-FPS. Hastighed og Pencil-følelse på ejerens iPad Pro skal bekræftes der.
