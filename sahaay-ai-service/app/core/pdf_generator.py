"""
Generates the SAHAAY "Donation Completion & Acknowledgement" PDF for a
completed donation. This is an IMPACT/ACKNOWLEDGMENT RECORD ONLY.

IMPORTANT: This is explicitly NOT a Section 80G tax-deduction certificate.
That requires official registration details and must be issued through proper
legal/accounting channels. The PDF prints a clear disclaimer to this effect.

Every value comes from the real records the backend sends; a null renders
"Not available" rather than an invented value. The layout mirrors the MITRA/
SAHAAY reference: a completion header, then six labelled sections, an
acknowledgement line and a verification footer.
"""

import os
from datetime import datetime
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import (
    HRFlowable,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

from app.config import PDF_OUTPUT_DIR
from app.models.schemas import DonationAcknowledgmentRequest

# Reference palette: blue section headings over pale-blue table headers.
_HEADING_BLUE = colors.HexColor("#1E5AA8")
_HEADER_BG = colors.HexColor("#E8F0FB")
_BORDER = colors.HexColor("#C9D6EA")
_TEXT = colors.HexColor("#1F2933")
_MUTED = colors.HexColor("#5B6B7C")
_BADGE_BG = colors.HexColor("#E3F2E1")
_BADGE_FG = colors.HexColor("#2E7D32")

_CONTENT_W = A4[0] - (2 * 18 * mm)

_TITLE = ParagraphStyle(
    "AckTitle", fontName="Helvetica-Bold", fontSize=16.5, leading=20,
    textColor=colors.HexColor("#152A4A"), alignment=1,
)
_SUBTITLE = ParagraphStyle(
    "AckSubtitle", fontName="Helvetica", fontSize=9.5, leading=13,
    textColor=_MUTED, alignment=1,
)
_BRAND = ParagraphStyle(
    "AckBrand", fontName="Helvetica-Bold", fontSize=16, leading=20,
    textColor=_HEADING_BLUE,
)
_BADGE = ParagraphStyle(
    "AckBadge", fontName="Helvetica-Bold", fontSize=9, leading=12,
    textColor=_BADGE_FG, alignment=1,
)
_COMPLETED = ParagraphStyle(
    "AckCompleted", fontName="Helvetica", fontSize=9.5, leading=13,
    textColor=_MUTED,
)
_SECTION = ParagraphStyle(
    "AckSection", fontName="Helvetica-Bold", fontSize=11, leading=14,
    textColor=_HEADING_BLUE,
)
_KEY = ParagraphStyle(
    "AckKey", fontName="Helvetica-Bold", fontSize=9, leading=12, textColor=_TEXT,
)
_VALUE = ParagraphStyle(
    "AckValue", fontName="Helvetica", fontSize=9, leading=12, textColor=_TEXT,
)
_CAPTION = ParagraphStyle(
    "AckCaption", fontName="Helvetica-Oblique", fontSize=7.5, leading=10,
    textColor=_MUTED,
)
_BODY = ParagraphStyle(
    "AckBody", fontName="Helvetica", fontSize=9, leading=12.5, textColor=_TEXT,
)
_FOOTER = ParagraphStyle(
    "AckFooter", fontName="Helvetica", fontSize=8, leading=11, textColor=_MUTED,
)
_FOOTER_BRAND = ParagraphStyle(
    "AckFooterBrand", fontName="Helvetica-Bold", fontSize=8.5, leading=11,
    textColor=_HEADING_BLUE,
)


def _text(value) -> str:
    """A real value as text, or an honest 'Not available' for null/empty.

    XML-escaped so a provider/NGO name or food description containing '&' or
    '<' renders literally rather than being read as ReportLab markup.
    """
    if value is None or value == "":
        return "Not available"
    return escape(str(value))


def _timestamp(value) -> str:
    """'24 Sep 2026 7:42 PM' — matches the reference (no leading zero)."""
    if value is None:
        return "Not available"
    hour12 = value.hour % 12 or 12
    return f"{value.day} {value.strftime('%b')} {value.year} {hour12}:{value.strftime('%M')} {value.strftime('%p')}"


def _time_only(value) -> str:
    if value is None:
        return "Not available"
    hour12 = value.hour % 12 or 12
    return f"{hour12}:{value.strftime('%M')} {value.strftime('%p')}"


def _yes_no(value) -> str:
    if value is None:
        return "Not available"
    return "Yes" if value else "No"


def _section(title: str, rows: list[tuple[str, object]]) -> Table:
    """A section banner (pale-blue, blue text) over key/value rows."""
    data: list[list[object]] = [[Paragraph(title, _SECTION), ""]]
    for key, value in rows:
        cell = value if isinstance(value, list) else Paragraph(value, _VALUE)
        data.append([Paragraph(key, _KEY), cell])

    table = Table(data, colWidths=[_CONTENT_W * 0.36, _CONTENT_W * 0.64])
    table.setStyle(
        TableStyle(
            [
                ("SPAN", (0, 0), (1, 0)),
                ("BACKGROUND", (0, 0), (-1, 0), _HEADER_BG),
                ("GRID", (0, 0), (-1, -1), 0.5, _BORDER),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("LEFTPADDING", (0, 0), (-1, -1), 8),
                ("RIGHTPADDING", (0, 0), (-1, -1), 8),
                ("TOPPADDING", (0, 0), (-1, -1), 2.5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2.5),
            ]
        )
    )
    return table


def _badge() -> Table:
    badge = Table([[Paragraph("COMPLETED", _BADGE)]], colWidths=[32 * mm])
    badge.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), _BADGE_BG),
                ("BOX", (0, 0), (-1, -1), 0.6, _BADGE_FG),
                ("ALIGN", (0, 0), (-1, -1), "CENTER"),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]
        )
    )
    return badge


def generate_acknowledgment_pdf(payload: DonationAcknowledgmentRequest) -> str:
    """Builds the PDF and returns the absolute file path where it was saved."""
    os.makedirs(PDF_OUTPUT_DIR, exist_ok=True)

    filename = f"acknowledgment_{payload.donation_id}.pdf"
    file_path = os.path.join(PDF_OUTPUT_DIR, filename)

    doc = SimpleDocTemplate(
        file_path,
        pagesize=A4,
        topMargin=11 * mm,
        bottomMargin=10 * mm,
        leftMargin=18 * mm,
        rightMargin=18 * mm,
        title="SAHAAY Donation Completion & Acknowledgement",
    )

    quantity_display = payload.quantity_label or (
        f"{payload.quantity_kg:g} kg" if payload.quantity_kg is not None else None
    )
    pickup = _time_only(payload.picked_up_at)
    delivery = _time_only(payload.delivered_at or payload.received_at)
    pickup_delivery = (
        "Not available"
        if pickup == "Not available" and delivery == "Not available"
        else f"{pickup} / {delivery}"
    )
    completed_at = (
        payload.completed_at
        or payload.received_at
        or payload.delivered_at
        or payload.handover_verified_at
        or payload.donation_datetime
    )

    elements: list = []

    # --- Header -----------------------------------------------------------
    elements.append(Paragraph("DONATION COMPLETION &amp; ACKNOWLEDGEMENT", _TITLE))
    elements.append(Spacer(1, 1.5 * mm))
    elements.append(Paragraph("Official donation completion record", _SUBTITLE))
    elements.append(Spacer(1, 3.5 * mm))

    header_row = Table(
        [[Paragraph("SAHAAY", _BRAND), _badge()]],
        colWidths=[_CONTENT_W * 0.6, _CONTENT_W * 0.4],
    )
    header_row.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("ALIGN", (1, 0), (1, 0), "RIGHT"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
            ]
        )
    )
    elements.append(header_row)
    elements.append(Spacer(1, 1.5 * mm))
    elements.append(
        Paragraph(f"Completed: {_timestamp(completed_at)}", _COMPLETED)
    )
    elements.append(
        HRFlowable(width="100%", thickness=0.8, color=_BORDER, spaceBefore=3, spaceAfter=7)
    )

    # --- Donation & Order Details ----------------------------------------
    elements.append(
        _section(
            "Donation &amp; Order Details",
            [
                ("Food Item", _text(payload.food_details)),
                ("Donation ID", _text(payload.donation_id)),
                ("Quantity", _text(quantity_display)),
                ("Est. Servings", _text(payload.servings)),
                ("Order ID", _text(payload.order_id)),
            ],
        )
    )
    elements.append(Spacer(1, 3 * mm))

    # --- Parties & Handover ----------------------------------------------
    elements.append(
        _section(
            "Parties &amp; Handover",
            [
                ("Donor / Provider", _text(payload.restaurant_name)),
                ("Receiving NGO", _text(payload.ngo_name)),
                ("Handover Status", _text(payload.handover_status)),
            ],
        )
    )
    elements.append(Spacer(1, 3 * mm))

    # --- Volunteer Details -----------------------------------------------
    elements.append(
        _section(
            "Volunteer Details",
            [
                ("Volunteer Involved", _yes_no(payload.volunteer_transport_used)),
                ("Volunteer Name", _text(payload.volunteer_name)),
                ("Role", _text(payload.volunteer_role)),
                ("Pickup / Delivery", pickup_delivery),
            ],
        )
    )
    elements.append(Spacer(1, 3 * mm))

    # --- Completion Timeline ---------------------------------------------
    elements.append(
        _section(
            "Completion Timeline",
            [
                (
                    "Posted",
                    [Paragraph(_timestamp(payload.posted_at), _VALUE),
                     Paragraph("Donation listed", _CAPTION)],
                ),
                (
                    "Claimed",
                    [Paragraph(_timestamp(payload.claimed_at), _VALUE),
                     Paragraph("NGO claim confirmed", _CAPTION)],
                ),
                (
                    "Picked Up",
                    [Paragraph(_timestamp(payload.picked_up_at), _VALUE),
                     Paragraph("Volunteer handover started", _CAPTION)],
                ),
                (
                    "Received",
                    [Paragraph(_timestamp(payload.received_at), _VALUE),
                     Paragraph("NGO receipt confirmed", _CAPTION)],
                ),
            ],
        )
    )
    elements.append(Spacer(1, 3 * mm))

    # --- Impact & Verification -------------------------------------------
    elements.append(
        _section(
            "Impact &amp; Verification",
            [
                ("Estimated Servings", _text(payload.servings)),
                ("NGO Supported", _text(payload.ngo_name)),
                ("NGO Receipt Confirmed", _yes_no(payload.ngo_receipt_confirmed)),
                ("Impact Points", _text(payload.impact_points)),
            ],
        )
    )
    elements.append(Spacer(1, 5 * mm))

    elements.append(
        Paragraph(
            "This report confirms completion and receipt of the donation "
            "recorded above through SAHAAY.",
            _BODY,
        )
    )
    elements.append(Spacer(1, 3 * mm))

    # --- Verification footer ---------------------------------------------
    elements.append(
        HRFlowable(width="100%", thickness=0.8, color=_BORDER, spaceAfter=6)
    )
    elements.append(Paragraph("VERIFICATION", _SECTION))
    elements.append(Spacer(1, 1.5 * mm))
    elements.append(Paragraph("QR / Digital Verification", _VALUE))
    elements.append(Spacer(1, 2 * mm))
    elements.append(
        Paragraph(
            "DEMO: This acknowledgment is generated for internal record-keeping "
            "and impact-reporting within the SAHAAY platform only. It is NOT a "
            "Section 80G tax-deduction certificate and must not be used as one.",
            _FOOTER,
        )
    )
    elements.append(Spacer(1, 2 * mm))
    elements.append(
        Paragraph("SAHAAY  Connecting Surplus With Need", _FOOTER_BRAND)
    )

    doc.build(elements)
    return file_path
