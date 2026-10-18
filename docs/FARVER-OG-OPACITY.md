# Farver og lagstyrke — version 0.5.0

Tryk på **farvecirklen øverst i studiet** for at åbne Colors. **Disc** viser et farvehjul: Ringen vælger farvetone, og firkanten i midten vælger mætning og lyshed. De tre skydere kan også bruges direkte og med tilgængelighedsværktøjer. **Values** skjuler hjulet og giver mere plads til præcise indstillinger.

Skriv en sekscifret HEX-farve, for eksempel `#327DD1`, og tryk **Apply** eller tastaturets **Done**. En ugyldig værdi ændrer ikke tegningsfarven. Panelet indeholder en fast studiopalet og op til 12 senest valgte farver pr. tegning. Farven gemmes som sRGB og gælder næste strøg. Tidligere streger beholder deres farve; penselskift ændrer ikke farvevalget. Alle 14 pensler og Mirror bruger den valgte farve. De store og små penselforhåndsvisninger følger også farven.

## Lag

Åbn **Layers**, og vælg et lag. Slideren **Layer opacity** styrer hele laget fra **0 til 100 %** og opdaterer lærredet undervejs. Ét slidertræk er én Undo-handling. Øjet på hver række slår laget til/fra uden at slette streger eller ændre lagets opacity. Skjulte lag er markeret **Hidden**. Skjul/vis og opacity gemmes i den redigerbare tegning.

Lagets opacity anvendes efter at alle streger på laget er samlet. To dækkende streger oven på hinanden på et lag med 50 % opacity får derfor samme lagstyrke som resten af laget. **Brush opacity** styrer hvert aftryk, mens **Layer opacity** styrer det færdige lag. Det er to forskellige indstillinger.

Et skjult eller låst lag kan ikke tegnes på. Et synligt lag med 0 % opacity kan stadig indeholde og modtage streger; hæv opacity for at se dem. Lagets position bestemmer rækkefølgen for både færdige og igangværende farvede strøg.

PNG-eksport og miniaturebilleder følger samme lagrækkefølge, farver, skjul/vis og samlede lagstyrke. Den redigerbare projektfil bevarer også skjulte lag. Format **5** kan importere ældre tegninger, hvor manglende farver bliver sort og manglende lag-opacity bliver 100 %. Gem en redigerbar kopi fra eksportmenuen før du erstatter dit Playground-projekt.

## Open source

Farvehjulet er tilpasset fra [ColorPickerRing af Hendrik Ulbrich](https://github.com/hendriku/ColorPicker/tree/fb251fa294637ee9ac5337bb678bf4b44f76abeb), under **MIT-licens**. Den originale licens medfølger i `ThirdParty/ColorPickerRing-LICENSE.txt`. Tilpasningen fjerner DynamicColor-afhængigheden, binder til vores gemte sRGB/HSB-model, gør taltyperne eksplicitte og tilføjer en separat mætning/lyshed-firkant. Ingen pakker skal hentes, når projektet åbnes på iPad.

Vi undersøgte også [SwiftUI-Color-Kit](https://github.com/kieranb662/SwiftUI-Color-Kit). Dets nuværende manifest kræver Swift tools 6.2 og en ekstra Sliders-pakke; den lille lokale tilpasning passer bedre til vores Swift tools 5.9-projekt. Det betyder ikke, at alle ældre Color Kit-versioner er inkompatible.

Farvehjul og præcise værdier er inspireret af arbejdsgangen beskrevet i [Procreates Color Disc-håndbog](https://help.procreate.com/procreate/handbook/colors/colors-disc). Procreate-kode og deres særlige indre farvedisk bruges ikke. Denne version understøtter sRGB; egne paletfiler, CMYK og fuld farveprofilstyring er senere arbejde.
