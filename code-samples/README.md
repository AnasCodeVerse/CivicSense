# Code samples

A few files from CivicSense that show the main logic behind the app. The full source code is available on request.

| File | What it does |
|---|---|
| [`classifier_service.dart`](classifier_service.dart) | Runs our TensorFlow Lite image model on the phone. It resizes and normalises the photo, runs the model, and returns the most likely class (pothole, garbage, or "normal" if there's no real issue). If the model fails, it returns "unavailable" so the resident can pick the category by hand. |
| [`uc_routing_and_duplicates.dart`](uc_routing_and_duplicates.dart) | Works out which Union Council a report belongs to with a point-in-polygon check against each UC's map boundary (UCs can have more than one land parcel). It also catches likely duplicates: an open complaint of the same category within 50 m in the last 7 days. |
| [`sla_config.dart`](sla_config.dart) | Deadlines for each category (e.g. water supply 1 day, potholes 7 days, encroachment 30 days) and the rules that label a complaint On track, Due soon, Overdue or Escalated. Complaints are escalated to Head Office once they pass 1.5× their deadline. |
