import test from "node:test";
import assert from "node:assert";
import React from "react";
import { Doppio } from "@doppio/js";
import { DoppioProvider, useDoppio } from "../dist/index.js";

test("React adapter: DoppioProvider provides client context", async () => {
  const client = await Doppio.init({
    flags: [{ key: "feature-x", enabled: true, rolloutPercentage: 100 }],
  });

  const element = React.createElement(
    DoppioProvider,
    { client },
    React.createElement("div", null, "child")
  );

  assert.ok(element);
  assert.strictEqual(element.props.client, client);
});
