# Billedlag og transformering — 0.8.9

Åbn menuen Gem/eksportér i topbjælken. Vælg **Insert photo** eller **Insert image file**. Fotos vælges i systemets billedvælger; filer understøtter PNG og JPEG. Billedet oprettes på et separat lag og åbnes i transformering.

- Træk billedet for at flytte det. Træk et hjørnehåndtag eller brug pinch for at skalere med bevarede proportioner.
- Drej med to fingre, eller brug knappen til 90 graders rotation. Knapperne med pile spejler vandret/lodret.
- **Apply** gemmer placeringen som én ændring, der kan fortrydes. **Cancel** beholder billedets tidligere placering. Annullering efter import beholder det nye billede i dets startplacering; Undo fjerner importen.
- Senere vælges **Transform image** i lagets menu eller Gem/eksportér-menuen. Låsning, synlighed, opacitet og rækkefølge bruger de normale lagkontroller.

Denne iteration flytter billedet på laget. Tegnede streger flyttes ikke med billedet; brug et separat lag til kontur og skygge. Markering og Mirror-masker følger i næste iteration. Billedet gentages ikke af tegningens Mirror-indstilling.

Den importerede arbejdskopi normaliseres én gang til højst 2048 pixels på længste led, med bevaret transparens og billedretning. Efterfølgende transformering ændrer kun placeringen, ikke PNG-data. Den samme billedtekstur genbruges under justering. De eksisterende grænser for billedhukommelse og filstørrelse gælder fortsat.

Projektformat 8 gemmer billedets placering. Appen læser stadig tidligere projektformater; ældre appversioner kan ikke åbne format 8.

Kontrol: lokale syntaks- og pakkekontroller. Målrettede Swift-tests er tilføjet for koordinater/format, import/Annuller/Anvend/Undo/Redo/genåbning og samme placering/farver i Metal og PNG. Apple-kompilering, tests og fysisk iPad/Pencil-adfærd skal bekræftes særskilt.
