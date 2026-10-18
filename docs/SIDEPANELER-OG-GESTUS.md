# Sidepaneler og tegnegestus — 0.8.0

## Venstre: størrelse og opacity

To lodrette sliders styrer den aktuelle pensel. Træk op for større/mere dækkende og ned for mindre/mere transparent. Størrelsen går fra 0,5 til 160 lærredspixels og har en finere skala ved små størrelser. Opacity går fra 1–100%. Tallene er synlige under justering. Viskelæderet bruger sine egne indstillinger; farvepenslen ændres ikke, når viskelæderet justeres. Kontrollerne låses under et igangværende strøg og ved farveopsamling.

Hver pensel husker sine indstillinger ved penselskift og mellem appstarter på samme installation. Den valgte pensel gemmes også i tegningen. Når et eksisterende projekt åbnes, vinder projektets indstilling for den aktive pensel. Penselændringer påvirker næste strøg; eksisterende strøg beholder deres udseende.

Opacity styrer farvens/removalens bidrag ved hver geometri-/penselaflejring. Overlappende dele kan derfor opbygge mere farve eller viskning, også inden for samme strøg. Lag-opacity er en separat kontrol, der dæmper hele laget én gang. Den tidligere helt dækkende Fineliner beholder sin oprindelige geometri og PNG-fyldning ved 100%. Lavere opacity bruger samme akkumulerende trekantdækning i Metal og PNG. Format 7 tillader dette for Fineliner og Brush pen; tidligere appversioner kan ikke åbne format 7. Version 0.8.0 åbner fortsat format 1–6.

Metal og PNG-eksportens Core Graphics glatter primitive kanter forskelligt. Ved transparent Fineliner/Brush pen kan det give små toneforskelle omkring de indre trekantkanter. Opacity kontrolleres på plane områder, og separate kantprøver måler filtreringsforskellen; der loves ikke fuld pixelidentitet mellem de to renderere.

## Størrelsescirkel

Under størrelsesjustering vises penslens maksimale diameter på lærredet. Cirklen følger lærredets zoom; ved trykfølsomhed er det størrelsen ved maksimalt tryk. Den bliver kortvarigt stående efter justeringen og skjules ved tegning. På en iPad/Pencil-kombination med hover følger cirklen pennen før berøring. Uden hover bruges cirklen midt på lærredet under justering.

Cirklen er et UIKit/Core Animation-overlay. Hover publicerer ingen dokumentrevision og starter ingen ny Metal-rendering. Den gemmes eller eksporteres ikke. Implementeringen bruger Apples [Pencil-hover via UIHoverGestureRecognizer](https://developer.apple.com/documentation/uikit/uihovergesturerecognizer).

## To og tre fingre

- Ét tryk med **to fingre**: Undo.
- Ét tryk med **tre fingre**: Redo.
- Træk med to fingre: flyt lærredet. Knib: zoom. Drej: rotation.

Der kræves ikke dobbelttryk. Tap-genkendelsen venter på, at navigationsgestus fejler, og to-finger-trykket venter også på tre-finger-genkendelsen. Et enkelt tryk skal derfor ikke både navigere og ændre historikken. Under Pencil-tegning er fingerhistorik og navigation slået fra. I valgfri fingertegning kasseres den foreløbige fingerstreg, så snart endnu en finger lægges på. Systemets egne tilgængelighedsgestus kan have forrang; knapperne Undo/Redo findes fortsat.

## Højre: lag

Lagpanelet viser miniature, navn, aktivt lag, synlighed, lås og indholdstæller. Øverst kan du oprette et lag og ændre det valgte lags opacity. Menuen ved hvert lag indeholder duplikering, sammenlægning, omdøbning, flyt op/ned og sletning. Panelet kan rulles, så alle op til 32 lag er tilgængelige.

Luk med pilen i panelets øverste højre hjørne. **Layers** i den nederste værktøjslinje åbner/lukker panelet. Åben/lukket huskes på installationen. Andre indstillingspaneler skjuler det midlertidigt, og fokusvisning skjuler begge sidepaneler. Lærredets ramme og tegnekoordinater ændres ikke, når panelerne skifter synlighed. Lagminiaturer hentes kun igen, når deres indholdsnøgle ændres; de eksisterende renderingscaches fra 0.7.0 er bevaret.

## Kontrol på iPad

Kontrollér **Ornamentalist 0.8.0** nederst i Canvas-panelet. Prøv størrelsesjustering, hover hvis understøttet, penselskift, viskelæder og fingerhistorik i en testtegning. Bekræft også, at to-finger-navigation ikke udløser Undo. Den automatiske simulator kan kontrollere fingerinput og koordinater, men ikke fysisk Pencil-hover, håndfladeafvisning eller den oplevede forsinkelse.
