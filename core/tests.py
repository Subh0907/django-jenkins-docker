from django.test import TestCase
from django.urls import reverse

from .models import Note


class CoreTests(TestCase):
    def test_health(self):
        response = self.client.get(reverse("health"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "ok"})

    def test_home_lists_notes(self):
        Note.objects.create(title="Deployment works", body="Jenkins deployed this app")
        response = self.client.get(reverse("home"))
        self.assertContains(response, "Deployment works")

