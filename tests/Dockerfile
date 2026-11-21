# Test runner for the portable Swift packages (LLMKit, RAGKit).
# Apple-only code paths (FoundationModels, NaturalLanguage, SQLite3, PDFKit, Vision) are compiled
# out on Linux; they are covered by the macOS CI job (see .github/workflows/ci.yml).
ARG SWIFT_IMAGE=swift:6.2
FROM ${SWIFT_IMAGE}

WORKDIR /work

# Sources are bind-mounted by docker-compose for live iteration; these COPYs make the image
# self-contained when it is run without volumes.
COPY Package.swift ./
COPY ios/Kit ios/Kit
COPY tests tests

# Build products go to /build (a named volume in compose), never into the bind mount or the host.
CMD ["swift", "test", "--build-path", "/build"]
