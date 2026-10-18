# Viskelæder, pipette og lag — version 0.6.0

## Viskelæder

Tryk på **viskelæderet øverst**. Knappen markeres, når værktøjet er aktivt. Tegn med Pencil som normalt: Der fjernes indhold på det valgte lag, og lagene nedenunder bliver synlige. Viskelæderet maler ikke med hvidt. Mirror og antallet af symmetrikopier følger de aktuelle indstillinger og fastholdes under strøget.

Åbn **Brushes**, mens viskelæderet er aktivt, for at vælge størrelse og **Hard / Soft**. Hard fjerner helt; Soft fjerner gradvist ved overlappende passager. Tryk på viskelæderknappen igen eller **Return to brush** for at tegne videre. Hvert viskelæderstrøg kan fortrydes med Undo, også efter at andre lag har været valgt. Skjulte/låste lag kan ikke viskes ud.

## Farvepipette

Tryk på **pipetten øverst**, og tryk derefter på tegningen med Pencil eller en finger. Farven vælges fra det synlige, sammensatte billede inklusive lag-opacity og den hvide papirbaggrund. Hjælpelinjer og studiets knapper indgår ikke. Værktøjet vender tilbage til penslen efter et vellykket valg, og farven føjes til de seneste farver. Pipetten laver ingen streg. Zoom, panorering og rotation bruger samme koordinatomregning som tegning.

I smal multitasking-visning ligger værktøjerne under **Drawing tools** i toppen.

## Miniaturebilleder og duplikering

Hvert lag har et miniaturebillede på et ternet gennemsigtighedsfelt. Billedet viser lagets eget indhold med fuld lagstyrke, også når laget er skjult; rækkens tekst og øje viser den aktuelle synlighed/opacity. Miniaturer beregnes i baggrunden og opdateres, når lagets indhold ændres.

Vælg lagets **… → Duplicate layer**. Kopien placeres lige over originalen og bliver valgt. Farver, Mirror, pensler, viskelæderstrøg, gennemsigtighed og præcise prikmønstre bevares. Den nye kopi er ulåst og beholder originalens synlighed. Undo fjerner kopien som én handling. Hvis dokumentets lag-/geometrigrænse overskrides, foretages kopieringen ikke.

## Sammenlægning

Vælg **… → Merge down** på det øverste af de to lag, du vil samle. Begge lag skal være synlige og ulåste. Panelet lukker, mens lagene samles; åbn **Layers** igen for at se resultatet. Deres indhold og aktuelle opacity samles til en transparent billedbund på det nederste lag; dette lag får 100 % opacity, mens det synlige samlede udseende bevares. Det nederste lags navn beholdes.

**Sammenlægning omdanner de to lags eksisterende strøg til pixels.** Undo gendanner de to originale, redigerbare lag med deres strøg, så længe tegningen stadig er åben. Efter gemning/lukning er den sammenlagte billedbund bevaret, og der kan tegnes og viskes videre ovenpå den. Eksportér et redigerbart projekt før en sammenlægning, hvis du vil bevare de to originale lag på længere sigt.

Sammenlægning understøtter i denne version lærreder op til **2048 × 2048** med hele pixeldimensioner, herunder appens standardlærred. Der er en samlet grænse på 16 megapixels og 24 MiB PNG-data til sammenlagte billedbunde pr. dokument. Filens eksisterende 64 MiB-grænse gælder fortsat. Afviste operationer efterlader tegningen uændret.

Version 0.6.0 gemmer format **6**. Ældre projekter kan importeres. De nye viskelæderstrøg, kopiernes mønsterfrø og sammenlagte billedbunde følger med ved redigerbar eksport/import. Hent hele den nye `Ornamentalist.swiftpm`; en eksisterende ZIP-kopi opdateres ikke automatisk af et Git-pull til en anden mappe.
