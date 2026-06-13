"""Captures routes — Phases C-D (voice port & log loop) fills these."""

from fastapi import APIRouter

router = APIRouter(prefix="/captures", tags=["captures"])
