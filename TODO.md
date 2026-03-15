Goal

Insert the network-control-plane-model stage between the forwarding model
and the renderer without changing renderer behavior.

The control-plane-model stage must initially behave as a pure pass-through.

No renderer logic must be modified in this phase.


Required changes

1. Introduce a new artifact

Create a new JSON file in the pipeline:

    output-control-plane-model.json


2. Update the pipeline

Current pipeline:

    network-forwarding-model → renderer

New pipeline:

    network-forwarding-model → network-control-plane-model → renderer


3. Run control-plane-model after forwarding-model

After generating:

    output-forwarding-model.json

execute the control-plane-model stage to produce:

    output-control-plane-model.json


4. Update renderer input

Change the renderer invocation so that it reads:

    output-control-plane-model.json

instead of:

    output-forwarding-model.json


5. Preserve renderer behavior

Renderer output must remain identical.

Specifically verify that the following artifacts are unchanged:

    containerlab topology
    generated bridges
    router configuration
    addressing
    routes


Constraints

Do NOT:

    move files
    refactor renderer logic
    modify routing behavior
    introduce new fields
    delete existing fields

The only change allowed is inserting the new stage and switching
renderer input to the new artifact.
