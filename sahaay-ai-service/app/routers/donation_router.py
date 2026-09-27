import os

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

from app.core.pdf_generator import generate_acknowledgment_pdf
from app.models.schemas import DonationAcknowledgmentRequest, DonationAcknowledgmentResponse

router = APIRouter(prefix="/api/v1/donation", tags=["Donation Acknowledgment"])


@router.post("/generate-acknowledgment", response_model=DonationAcknowledgmentResponse)
def generate_acknowledgment_endpoint(payload: DonationAcknowledgmentRequest):
    """
    Generates a PDF acknowledgment receipt for a completed donation.
    Returns the file path; use GET /download/{donation_id} to fetch the
    actual PDF bytes.
    """
    try:
        file_path = generate_acknowledgment_pdf(payload)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"PDF generation failed: {exc}") from exc

    return DonationAcknowledgmentResponse(
        donation_id=payload.donation_id,
        pdf_filename=os.path.basename(file_path),
        file_path=file_path,
        message="Acknowledgment PDF generated successfully.",
    )


@router.get("/download/{donation_id}")
def download_acknowledgment_endpoint(donation_id: str):
    """Downloads the previously generated PDF for a given donation_id."""
    from app.config import PDF_OUTPUT_DIR

    filename = f"acknowledgment_{donation_id}.pdf"
    file_path = os.path.join(PDF_OUTPUT_DIR, filename)

    if not os.path.exists(file_path):
        raise HTTPException(
            status_code=404,
            detail=f"No acknowledgment PDF found for donation_id '{donation_id}'. "
            f"Generate it first via POST /api/v1/donation/generate-acknowledgment.",
        )

    return FileResponse(file_path, media_type="application/pdf", filename=filename)
