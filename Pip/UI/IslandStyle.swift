import SwiftUI

/// The island's surfaces: four white opacities over black, set by the search bar.
enum IslandStyle {

    // MARK: Controls — things you press

    /// The search bar's resting fill, also the field, keycaps and chips.
    static let controlFill = 0.105
    /// The hairline that turns a fill into an object. One value for every
    /// control, which is most of what stops the panel looking assembled from
    /// parts.
    static let controlStroke = 0.09
    /// The bar under the pointer. Kept a clear step above the resting fill
    /// rather than a nudge — a hover you have to look for isn't feedback.
    static let controlHover = 0.145
    /// A control that is the main action, under the pointer — the play
    /// button, the utility row's primary button. One step above hover, so the
    /// filled control still answers the pointer.
    static let controlActive = 0.22

    // MARK: Surfaces — things that hold content

    /// The detail card: a step below a control.
    static let surfaceFill = 0.06

    // MARK: Selection

    /// The same as `controlHover`: hover and selection say the same thing.
    static let selectionFill = 0.145
    /// A touch stronger than `controlStroke`, because the selected row has to
    /// win against the rows either side of it rather than against black.
    static let selectionStroke = 0.13

    // MARK: Rules

    /// Section headings, the footer's top edge.
    static let hairline = 0.08

    /// Thumbnail borders: stronger, as they sit on images of any colour.
    static let imageStroke = 0.14
}
