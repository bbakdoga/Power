"""Label Studio labeling configuration generated from the taxonomy."""

from __future__ import annotations

from xml.sax.saxutils import quoteattr

from .taxonomy import Taxonomy


def labeling_config(taxonomy: Taxonomy) -> str:
    labels = "\n".join(
        f"    <Label value={quoteattr(c.name)} hint={quoteattr(c.display_name)}/>"
        for c in sorted(taxonomy.active, key=lambda c: c.id)
    )
    unknown = taxonomy.unknown
    return f"""<View>
  <Header value="Draw one box around every separate food. Read docs/annotation_guidelines.md first."/>
  <Image name="image" value="$image" zoom="true" zoomControl="true" rotateControl="false"/>
  <RectangleLabels name="label" toName="image" strokeWidth="2" canRotate="false">
    <Label value={quoteattr(unknown.name)} hint="Food not in the list, or you cannot tell what it is" background="#888888"/>
{labels}
  </RectangleLabels>
  <Choices name="flags" toName="image" perRegion="true" choice="multiple" showInline="true">
    <Choice value="occluded" hint="More than a quarter of the food is hidden"/>
    <Choice value="truncated" hint="The food is cut off by the photo edge"/>
    <Choice value="uncertain" hint="You are not sure about the label"/>
    <Choice value="mixed_dish" hint="Box covers a dish whose parts cannot be separated"/>
  </Choices>
  <Choices name="image_flags" toName="image" choice="multiple" showInline="true">
    <Choice value="no_food" hint="The photo contains no food at all"/>
    <Choice value="reject_image" hint="Blurry, private, or not a real photo; exclude it"/>
  </Choices>
</View>
"""
