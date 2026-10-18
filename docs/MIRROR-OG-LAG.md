# Mirror og lag — version 0.3.0

## Spejling

Åbn **Symmetry → Mirror**. Hver ny streg får både de roterede kopier og deres spejlinger omkring hjælpeakserne. Med 8 sektorer og Mirror får du 16 kopier; med 64 sektorer får du 128. Med 1 sektor og Mirror får du et enkelt spejlpar omkring den vandrette hjælpelinje gennem centrum.

Hjælpelinjerne viser alle spejlaksers retninger, når Mirror er slået til. Mirror og antallet af sektorer fastholdes i hver streg, mens du tegner. Ændringer påvirker kun efterfølgende streger. Mirror følger med ved gemning, gendannelse og eksport.

## Lag

Åbn **Layers** i værktøjslinjen. Øverste række er det øverste lag på lærredet.

- **Add layer:** opretter og vælger et nyt tomt lag, op til 32 lag.
- Tryk på et lag for at vælge det. Nye streger tilhører det valgte lag.
- **Øje:** viser/skjuler laget. Skjulte lag indgår ikke i lærred, miniature eller PNG.
- **Lås:** beskytter laget mod nye streger. Et skjult lag kan heller ikke tegnes på. Vælg et andet lag eller lås/vis det igen.
- **Prikmenu:** omdøb, flyt op/ned eller slet. Sletning kræver bekræftelse; tegningen beholder altid mindst ét lag.
- **Undo/Redo:** fortryder/gendanner streger og laghandlinger på tværs af lag. Slettede lag gendannes med deres oprindelige streger og rækkefølge. Historikken gælder den aktuelle åbne tegnesession.

Lagvalg, rækkefølge, synlighed, lås og navne gemmes i projektet. Redigerbare eksporter indeholder også skjulte lag. PNG og miniature indeholder kun synlige lag. Lag har i denne version fuld opacitet og normal blanding; fletning, duplikering og opacitet er endnu ikke implementeret.

Ældre tegninger åbnes med alle eksisterende streger på **Layer 1** og Mirror slået fra. Version 3 af dokumentformatet bevarer de gamle stregindstillinger. Nye version 3-filer kræver en opdateret app og kan ikke læses af 0.2.x. Eksportér dine eksisterende tegninger som redigerbare projekter før du erstatter dit Playground-projekt, og importér dem i den nye kopi efter behov.

## Kontrol på fysisk iPad

1. Tegn en asymmetrisk kurve ved en hjælpelinje med Mirror slået til. Begge sider skal vokse, mens Pencil stadig rører skærmen. Slå Mirror fra og tegn igen; den første streg skal beholde sin spejling.
2. Opret et nyt lag og tegn en anden figur. Skjul laget, vis det igen, og lås det. Kontrollér at det låste/skjulte lag ikke får nye streger.
3. Omdøb og flyt laget. Slet det og brug Undo/Redo. Streger og lag skal komme tilbage sammen.
4. Gem, gå til Gallery og genåbn. Kontrollér både Mirror og lagvalg, navne, rækkefølge og lås/synlighed.
5. Eksportér PNG med et skjult lag og derefter et redigerbart projekt. PNG skal udelade det skjulte lag; den redigerbare fil skal bevare det.
