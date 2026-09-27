"""
Generates a PDF acknowledgment receipt after a donation is marked
completed. This is an IMPACT/ACKNOWLEDGMENT RECEIPT ONLY.

IMPORTANT: This is explicitly NOT a Section 80G tax-deduction
certificate. That requires official registration details and must be
issued through proper legal/accounting channels. The PDF prints a
clear disclaimer to this effect.
"""

import os
from datetime import datetime

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

from app.config import PDF_OUTPUT_DIR
from app.models.schemas import DonationAcknowledgmentRequest


def generate_acknowledgment_pdf(payload: DonationAcknowledgmentRequest) -> str:
    """
    Builds the PDF and returns the absolute file path where it was saved.
    """
    os.makedirs(PDF_OUTPUT_DIR, exist_ok=True)

    filename = f"acknowledgment_{payload.donation_id}.pdf"
    file_path = os.path.join(PDF_OUTPUT_DIR, filename)

    styles = getSampleStyleSheet()
    title_style = ParagraphStyle(
        "SahaayTitle", parent=styles["Title"], textColor=colors.HexColor("#1B5E20")
    )
    disclaimer_style = ParagraphStyle(
        "Disclaimer", parent=styles["Normal"], fontSize=8, textColor=colors.grey
    )

    doc = SimpleDocTemplate(
        file_path,
        pagesize=A4,
        topMargin=20 * mm,
        bottomMargin=20 * mm,
    )

    elements = []

    elements.append(Paragraph("SAHAAY", title_style))
    elements.append(Paragraph("Food Wastage Prediction and Redistribution Platform", styles["Normal"]))
    elements.append(Spacer(1, 6 * mm))
    elements.append(Paragraph("Donation Acknowledgment Receipt", styles["Heading2"]))
    elements.append(Spacer(1, 4 * mm))

    data = [
        ["Donation ID", payload.donation_id],
        ["Restaurant Name", payload.restaurant_name],
        ["NGO Name", payload.ngo_name],
        ["Food Details", payload.food_details],
        ["Quantity (kg)", str(payload.quantity_kg)],
        ["Donation Date & Time", payload.donation_datetime.strftime("%d-%b-%Y %I:%M %p")],
        ["Completion Status", payload.completion_status],
        ["Receipt Generated On", datetime.now().strftime("%d-%b-%Y %I:%M %p")],
    ]

    table = Table(data, colWidths=[55 * mm, 105 * mm])
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (0, -1), colors.HexColor("#E8F5E9")),
                ("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("FONTNAME", (0, 0), (0, -1), "Helvetica-Bold"),
                ("FONTSIZE", (0, 0), (-1, -1), 10),
                ("TOPPADDING", (0, 0), (-1, -1), 6),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
                ("LEFTPADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )
    elements.append(table)
    elements.append(Spacer(1, 10 * mm))

    elements.append(
        Paragraph(
            "This document acknowledges the successful completion of the above food "
            "donation for impact-reporting purposes within the SAHAAY platform.",
            styles["Normal"],
        )
    )
    elements.append(Spacer(1, 6 * mm))

    elements.append(
        Paragraph(
            "DISCLAIMER: This acknowledgment receipt is generated for internal "
            "record-keeping and impact-reporting purposes only. It is NOT a Section "
            "80G tax-deduction certificate and must not be used or presented as one. "
            "For an official tax-deduction certificate, please contact the recipient "
            "NGO's registered accounting/legal office directly.",
            disclaimer_style,
        )
    )

    doc.build(elements)
    return file_path
