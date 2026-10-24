import SwiftUI

/// Accessibility identifiers for UI tests and VoiceOver-driven automation.
public enum AccessibilityID {
    public static let repositoryList = "repositories.list"
    public static let addRepository = "repositories.add"
    public static let branchTable = "branches.table"
    public static let scopePicker = "branches.scope"
    public static let prefixMenu = "branches.prefix"
    public static let refresh = "branches.refresh"
    public static let statusLine = "branches.status"
    public static let detail = "branch.detail"
    public static let detailCommits = "branch.detail.commits"
    public static let detailFiles = "branch.detail.files"
    public static let detailOverlaps = "branch.detail.overlaps"
}

/// Layout values in one place; sizes are minimums so the window still adapts to the screen.
public enum Layout {
    /// Sum of the three pane minimums, so no pane is ever squeezed below its own minimum.
    static let windowMinWidth: CGFloat = sidebarMinWidth + tableMinWidth + detailMinWidth
    /// First-launch size: room for the table's seven columns plus the detail pane on a laptop screen.
    public static let windowDefaultWidth: CGFloat = 1440
    public static let windowDefaultHeight: CGFloat = 860
    static let windowMinHeight: CGFloat = 560
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 220
    static let tableMinWidth: CGFloat = 520
    static let detailMinWidth: CGFloat = 320
    static let detailIdealWidth: CGFloat = 360
    /// Capped so the table keeps room for all seven columns.
    static let detailMaxWidth: CGFloat = 480
    static let tableIdealWidth: CGFloat = 860
    static let branchColumnMin: CGFloat = 180
    static let branchColumnIdeal: CGFloat = 220
    static let branchColumnMax: CGFloat = 420
    static let notesColumnMin: CGFloat = 100
    static let notesColumnIdeal: CGFloat = 180
    static let whereColumnIdeal: CGFloat = 60
    static let dateColumnIdeal: CGFloat = 90
    static let authorColumnIdeal: CGFloat = 110
    static let comparisonColumnIdeal: CGFloat = 84
    static let narrowColumnMin: CGFloat = 56
    static let sectionSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 4
    static let badgeHorizontalPadding: CGFloat = 6
    static let badgeVerticalPadding: CGFloat = 2
    static let badgeCornerRadius: CGFloat = 4
    static let badgeBackgroundOpacity = 0.15
    /// Detail lists show this many files, then a count — long-lived branches can touch thousands.
    static let detailFileLimit = 200
    static let overlapFilePreview = 5
}

/// SF Symbols used in more than one place.
enum Symbol {
    static let repository = "folder"
    static let add = "plus"
    static let refresh = "arrow.clockwise"
    static let branch = "arrow.triangle.branch"
    static let warning = "exclamationmark.triangle"
    static let revealInFinder = "magnifyingglass"
    static let remove = "minus.circle"
    static let prefix = "line.3.horizontal.decrease.circle"
}
