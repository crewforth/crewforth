namespace Demo.Core;

public static class Orders
{
    // WHY: totals are rounded once, at the end, so a split order adds up to the same cents as the whole.
    public static decimal Total(decimal[] lines) => System.Math.Round(lines.Sum(), 2);

    // HACK: the legacy importer sends negative quantities for returns; clamp until it is fixed.
    public static int Quantity(int raw) => raw < 0 ? 0 : raw; /* FIXME(#12): remove with the importer */

    // Not a marker: the HACKATHON build, a FIXMEs list, and "WHY" in a string below stay out.
    public const string Note = "// WHY this is a string";
}
