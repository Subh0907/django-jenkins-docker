from django.http import JsonResponse
from django.shortcuts import render

from .models import Note


def home(request):
    return render(request, "core/home.html", {"notes": Note.objects.order_by("-created_at")})


def health(request):
    return JsonResponse({"status": "ok"})

